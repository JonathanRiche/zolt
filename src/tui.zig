//! Minimal single-pane TUI with vim-style navigation and slash commands.

const std = @import("std");
const builtin = @import("builtin");

const keybindings = @import("keybindings.zig");
const models = @import("models.zig");
const patch_tool = @import("patch_tool.zig");
const provider_client = @import("provider_client.zig");
const tools_runtime = @import("tools/runtime.zig");
const Paths = @import("paths.zig").Paths;
const AppState = @import("state.zig").AppState;
const Conversation = @import("state.zig").Conversation;
const Message = @import("state.zig").Message;
const Role = @import("state.zig").Role;
const TokenUsage = @import("state.zig").TokenUsage;
const Keybindings = keybindings.Keybindings;

const Mode = enum {
    normal,
    insert,
};

const ProviderAuthSource = enum {
    api_key_env,
    codex_subscription,
};

pub const OpenAiAuthMode = enum {
    auto,
    api_key,
    codex,
};

const ResolvedProviderAuth = struct {
    bearer_token: []u8,
    chatgpt_account_id: ?[]u8 = null,
    prefer_responses_api: bool = false,
    base_url_override: ?[]const u8 = null,
    source: ProviderAuthSource = .api_key_env,

    fn deinit(self: *ResolvedProviderAuth, allocator: std.mem.Allocator) void {
        allocator.free(self.bearer_token);
        if (self.chatgpt_account_id) |account_id| allocator.free(account_id);
    }
};

pub const Theme = enum {
    codex,
    plain,
    forest,
};

pub const StartupOptions = struct {
    theme: ?Theme = null,
    compact_mode: ?bool = null,
    keybindings: ?Keybindings = null,
    openai_auth_mode: ?OpenAiAuthMode = null,
    auto_compact_percent_left: ?i64 = null,
};

pub const RunTaskEvent = union(enum) {
    token: []const u8,
    tool_call: []const u8,
    tool_result: []const u8,
    final: []const u8,
};

pub const RunTaskObserver = struct {
    on_event: *const fn (context: ?*anyopaque, event: RunTaskEvent) anyerror!void,
    context: ?*anyopaque = null,
};

pub const RunTaskErrorInfo = struct {
    code: []u8,
    message: []u8,
    retryable: bool,
    source: []u8,

    pub fn deinit(self: *RunTaskErrorInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.message);
        allocator.free(self.source);
    }
};

pub const RunTaskOutcome = struct {
    response: []u8,
    error_info: ?RunTaskErrorInfo = null,

    pub fn deinit(self: *RunTaskOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.response);
        if (self.error_info) |*err_info| err_info.deinit(allocator);
    }
};

const StreamTask = enum {
    idle,
    thinking,
    responding,
    compacting,
    running_read,
    running_list_dir,
    running_read_file,
    running_grep_files,
    running_project_search,
    running_apply_patch,
    running_exec_command,
    running_write_stdin,
    running_web_search,
    running_view_image,
    running_skill,
};

const CommandPickerKind = enum {
    slash_commands,
    quick_actions,
    conversation_switch,
    provider_options,
};

const TerminalMetrics = struct {
    width: usize,
    lines: usize,
};

const CommandSession = struct {
    id: u32,
    command_line: []u8,
    child: std.process.Child,
    finished: bool = false,
    term: ?std.process.Child.Term = null,
};

const ExecCommandInput = struct {
    cmd: []u8,
    yield_ms: u32 = COMMAND_TOOL_DEFAULT_YIELD_MS,
};

const WriteStdinInput = struct {
    session_id: u32,
    chars: []u8,
    yield_ms: u32 = COMMAND_TOOL_DEFAULT_YIELD_MS,
};

const WebSearchEngine = enum {
    duckduckgo,
    exa,
};

const WebSearchInput = struct {
    query: []u8,
    limit: u8 = WEB_SEARCH_DEFAULT_RESULTS,
    engine: WebSearchEngine = .duckduckgo,
};

const ViewImageInput = struct {
    path: []u8,
};

const ListDirInput = struct {
    path: []u8,
    recursive: bool = false,
    max_entries: u16 = LIST_DIR_DEFAULT_MAX_ENTRIES,
};

const ReadFileInput = struct {
    path: []u8,
    max_bytes: u32 = READ_FILE_DEFAULT_MAX_BYTES,
};

const GrepFilesInput = struct {
    query: []u8,
    path: []u8,
    glob: ?[]u8 = null,
    max_matches: u16 = GREP_FILES_DEFAULT_MAX_MATCHES,

    fn deinit(self: *GrepFilesInput, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        allocator.free(self.path);
        if (self.glob) |glob| allocator.free(glob);
    }
};

const ProjectSearchInput = struct {
    query: []u8,
    path: []u8,
    max_files: u8 = PROJECT_SEARCH_DEFAULT_MAX_FILES,
    max_matches: u16 = PROJECT_SEARCH_DEFAULT_MAX_MATCHES,

    fn deinit(self: *ProjectSearchInput, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        allocator.free(self.path);
    }
};

const ProjectSearchFileHit = struct {
    path: []u8,
    hits: u32 = 0,
    first_line: u32 = 0,
    first_col: u32 = 0,
    first_snippet: []u8,

    fn deinit(self: *ProjectSearchFileHit, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.first_snippet);
    }
};

const WebSearchResultItem = struct {
    title: []u8,
    url: []u8,

    fn deinit(self: *WebSearchResultItem, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
    }
};

const ApplyPatchPreview = struct {
    text: []u8,
    included_lines: usize,
    omitted_lines: usize,
};

const SessionDrainResult = struct {
    stdout: []u8,
    stderr: []u8,
    output_limited: bool = false,
};

const StreamFailureInfo = struct {
    code: []u8,
    message: []u8,
    retryable: bool,
    context_related: bool,
    source: []u8,
};

const SkillScope = enum {
    project,
    global,
};

const SkillInfo = struct {
    name: []u8,
    description: []u8,
    path: []u8,
    base_dir: []u8,
    scope: SkillScope,

    fn deinit(self: *SkillInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.path);
        allocator.free(self.base_dir);
    }
};

const VisionCaptionResult = struct {
    caption: ?[]u8 = null,
    error_detail: ?[]u8 = null,
};

const ImageFileInfo = struct {
    bytes: u64,
    format: []const u8,
    mime: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
    sha256_hex: ?[]u8 = null,

    fn deinit(self: *ImageFileInfo, allocator: std.mem.Allocator) void {
        if (self.sha256_hex) |sha| allocator.free(sha);
    }
};

const ClipboardImageCapture = struct {
    bytes: []u8,
    mime: []const u8,
};

const MODEL_PICKER_MAX_ROWS: usize = 8;
const FILE_PICKER_MAX_ROWS: usize = 8;
const COMMAND_PICKER_MAX_ROWS: usize = 8;
const TOOL_MAX_STEPS: usize = 4;
const READ_TOOL_MAX_OUTPUT_BYTES: usize = 24 * 1024;
const APPLY_PATCH_TOOL_MAX_PATCH_BYTES: usize = 256 * 1024;
const APPLY_PATCH_PREVIEW_MAX_LINES: usize = 120;
const COMMAND_TOOL_MAX_OUTPUT_BYTES: usize = 24 * 1024;
const COMMAND_TOOL_DEFAULT_YIELD_MS: u32 = 700;
const COMMAND_TOOL_MAX_YIELD_MS: u32 = 5000;
const COMMAND_TOOL_MAX_SESSIONS: usize = 8;
const WEB_SEARCH_DEFAULT_RESULTS: u8 = 5;
const WEB_SEARCH_MAX_RESULTS: u8 = 10;
const WEB_SEARCH_MAX_RESPONSE_BYTES: usize = 256 * 1024;
const IMAGE_TOOL_MAX_FILE_BYTES: usize = 64 * 1024 * 1024;
const IMAGE_VISION_MAX_BYTES: usize = 6 * 1024 * 1024;
const CLIPBOARD_IMAGE_MAX_BYTES: usize = 32 * 1024 * 1024;
const LIST_DIR_DEFAULT_MAX_ENTRIES: u16 = 200;
const LIST_DIR_MAX_ENTRIES: u16 = 1000;
const READ_FILE_DEFAULT_MAX_BYTES: u32 = 12 * 1024;
const READ_FILE_MAX_BYTES: u32 = 256 * 1024;
const GREP_FILES_DEFAULT_MAX_MATCHES: u16 = 200;
const GREP_FILES_MAX_MATCHES: u16 = 2000;
const GREP_FILES_MAX_OUTPUT_BYTES: usize = 128 * 1024;
const PROJECT_SEARCH_DEFAULT_MAX_FILES: u8 = 8;
const PROJECT_SEARCH_MAX_FILES: u8 = 24;
const PROJECT_SEARCH_DEFAULT_MAX_MATCHES: u16 = 300;
const PROJECT_SEARCH_MAX_MATCHES: u16 = 5000;
const STREAM_INTERRUPT_ESC_WINDOW_MS: i64 = 1200;
const OPENAI_CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex";
const FILE_INJECT_MAX_FILES: usize = 8;
const FILE_INJECT_MAX_FILE_BYTES: usize = 64 * 1024;
const FILE_INJECT_HEADER = "[file-inject]";
const SKILL_INJECT_HEADER = "[skill-inject]";
const AGENTS_CONTEXT_HEADER = "[agents-context]";
const SKILLS_CONTEXT_HEADER = "[skills-context]";
const COMPACT_SUMMARY_HEADER = "[compact-summary]";
const COMPACT_NOTE_HEADER = "[compact]";
const AGENTS_CONTEXT_MAX_FILE_BYTES: usize = 128 * 1024;
const AGENTS_CONTEXT_MAX_INSTRUCTIONS_BYTES: usize = 24 * 1024;
const SKILL_FILE_MAX_BYTES: usize = 256 * 1024;
const SKILLS_CONTEXT_MAX_ENTRIES: usize = 32;
const FILE_INDEX_MAX_OUTPUT_BYTES: usize = 32 * 1024 * 1024;
const AUTO_COMPACT_PERCENT_LEFT_THRESHOLD: i64 = 15;
const AUTO_COMPACT_MIN_MESSAGES: usize = 10;
const COMPACT_KEEP_RECENT_MESSAGES: usize = 8;
const COMPACT_MIN_SOURCE_MESSAGES: usize = 4;
const COMPACT_LOCAL_FALLBACK_MAX_LINES: usize = 8;
const COMPACT_LOCAL_FALLBACK_PREVIEW_CHARS: usize = 200;
const COMPACT_SUMMARY_SYSTEM_PROMPT =
    "You are compacting chat history for a coding assistant.\n" ++
    "Produce a concise summary preserving user goals, constraints, decisions, unresolved questions, and pending tasks.\n" ++
    "Do not call tools. Do not add XML tags. Use short bullet points.\n";
const COMPACT_SUMMARY_USER_PROMPT =
    "Summarize the prior conversation now. Keep it compact and high-signal for continuing work.";
const KEY_UP_ARROW: u8 = keybindings.KEY_UP_ARROW;
const KEY_DOWN_ARROW: u8 = keybindings.KEY_DOWN_ARROW;
const KEY_PAGE_UP: u8 = keybindings.KEY_PAGE_UP;
const KEY_PAGE_DOWN: u8 = keybindings.KEY_PAGE_DOWN;
const TOOL_SYSTEM_PROMPT =
    "You can use eleven local tools.\n" ++
    "When you need to inspect files, reply with ONLY:\n" ++
    "<READ>\n" ++
    "<command>\n" ++
    "</READ>\n" ++
    "Allowed commands: rg, grep, ls, cat, find, head, tail, sed, wc, stat, pwd, and limited git read-only commands.\n" ++
    "For git via READ, only these subcommands are allowed: status, diff, show, log, rev-parse, ls-files.\n" ++
    "Do not claim you lack repository/file access unless a tool call fails.\n" ++
    "If the user asks what changed/what they did/updates/history, inspect with READ first (for example: git status, git diff, git log --oneline -n 20).\n" ++
    "Prefer these structured discovery tools when possible:\n" ++
    "<LIST_DIR>\n" ++
    "{\"path\":\"src\",\"recursive\":false,\"max_entries\":200}\n" ++
    "</LIST_DIR>\n" ++
    "<READ_FILE>\n" ++
    "{\"path\":\"src/main.zig\",\"max_bytes\":12288}\n" ++
    "</READ_FILE>\n" ++
    "<GREP_FILES>\n" ++
    "{\"query\":\"TODO\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_matches\":200}\n" ++
    "</GREP_FILES>\n" ++
    "<PROJECT_SEARCH>\n" ++
    "{\"query\":\"token usage\",\"path\":\".\",\"max_files\":8,\"max_matches\":300}\n" ++
    "</PROJECT_SEARCH>\n" ++
    "When you need to edit files, reply with ONLY:\n" ++
    "<APPLY_PATCH>\n" ++
    "*** Begin Patch\n" ++
    "*** Update File: path/to/file\n" ++
    "@@\n" ++
    "-old text\n" ++
    "+new text\n" ++
    "*** End Patch\n" ++
    "</APPLY_PATCH>\n" ++
    "For shell commands, start/continue with:\n" ++
    "<EXEC_COMMAND>\n" ++
    "{\"cmd\":\"ls -la\",\"yield_ms\":700}\n" ++
    "</EXEC_COMMAND>\n" ++
    "To send input to an existing session:\n" ++
    "<WRITE_STDIN>\n" ++
    "{\"session_id\":1,\"chars\":\"pwd\\n\",\"yield_ms\":700}\n" ++
    "</WRITE_STDIN>\n" ++
    "For web search, use:\n" ++
    "<WEB_SEARCH>\n" ++
    "{\"query\":\"zig 0.15 release notes\",\"limit\":5,\"engine\":\"duckduckgo\"}\n" ++
    "</WEB_SEARCH>\n" ++
    "For image metadata inspection, use:\n" ++
    "<VIEW_IMAGE>\n" ++
    "{\"path\":\"/absolute/or/relative/image.png\"}\n" ++
    "</VIEW_IMAGE>\n" ++
    "For skill loading, use:\n" ++
    "<SKILL>\n" ++
    "{\"name\":\"skill-name\"}\n" ++
    "</SKILL>\n" ++
    "Available skill names/descriptions are provided in [skills-context] messages.\n" ++
    "After a system message that starts with [read-result], [list-dir-result], [read-file-result], [grep-files-result], [project-search-result], [apply-patch-result], [exec-result], [write-stdin-result], [web-search-result], [view-image-result], or [skill-result], continue the answer normally.";

const VIEW_IMAGE_VISION_PROMPT =
    "Describe this image for a coding assistant. Focus on visible UI/text/code, layout, key errors/warnings, and actionable observations. Keep it concise.";

const RawMode = struct {
    original_termios: std.posix.termios,

    pub fn enable() !RawMode {
        const stdin_handle = std.fs.File.stdin().handle;
        const original = try std.posix.tcgetattr(stdin_handle);

        var raw = original;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_handle, .NOW, raw);

        return .{ .original_termios = original };
    }

    pub fn disable(self: *const RawMode) void {
        const stdin_handle = std.fs.File.stdin().handle;
        std.posix.tcsetattr(stdin_handle, .NOW, self.original_termios) catch {};
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    paths: *const Paths,
    app_state: *AppState,
    catalog: *models.Catalog,
    startup_options: StartupOptions,
) !void {
    var app: App = .{
        .allocator = allocator,
        .paths = paths,
        .app_state = app_state,
        .catalog = catalog,
        .notice = try allocator.dupe(u8, "Press i for insert mode. Type /help for commands."),
    };
    defer app.deinit();
    if (startup_options.theme) |theme| {
        app.theme = theme;
    }
    if (startup_options.compact_mode) |compact_mode| {
        app.compact_mode = compact_mode;
    }
    if (startup_options.keybindings) |bindings| {
        app.keybindings = bindings;
    }
    if (startup_options.openai_auth_mode) |auth_mode| {
        app.openai_auth_mode = auth_mode;
    }
    if (startup_options.auto_compact_percent_left) |percent_left| {
        app.auto_compact_percent_left = normalizeAutoCompactPercentLeft(percent_left);
    }
    app.ensureCurrentConversationVisibleInStrip();

    var raw_mode = try RawMode.enable();
    defer raw_mode.disable();

    try app.render();

    while (!app.should_exit) {
        var byte_buf: [1]u8 = undefined;
        const read_len = try std.posix.read(std.fs.File.stdin().handle, byte_buf[0..]);
        if (read_len == 0) break;

        if (byte_buf[0] == 26) {
            app.suspend_requested = true;
        }

        if (app.suspend_requested) {
            try suspendForJobControl(&raw_mode, &app);
            continue;
        }

        const mapped_key = if (byte_buf[0] == 27) try mapEscapeSequenceToKey() else null;
        if (mapped_key) |key| {
            try app.handleByte(key);
        } else {
            try app.handleByte(byte_buf[0]);
        }

        if (app.suspend_requested) {
            try suspendForJobControl(&raw_mode, &app);
            continue;
        }

        if (!app.should_exit) {
            try app.render();
        }
    }
}

pub fn runTaskPrompt(
    allocator: std.mem.Allocator,
    paths: *const Paths,
    app_state: *AppState,
    catalog: *models.Catalog,
    prompt: []const u8,
    startup_options: StartupOptions,
) ![]u8 {
    var outcome = try runTaskPromptOutcomeWithObserver(
        allocator,
        paths,
        app_state,
        catalog,
        prompt,
        startup_options,
        null,
    );
    defer if (outcome.error_info) |*err_info| err_info.deinit(allocator);
    return outcome.response;
}

pub fn runTaskPromptWithObserver(
    allocator: std.mem.Allocator,
    paths: *const Paths,
    app_state: *AppState,
    catalog: *models.Catalog,
    prompt: []const u8,
    startup_options: StartupOptions,
    run_observer: ?RunTaskObserver,
) ![]u8 {
    var outcome = try runTaskPromptOutcomeWithObserver(
        allocator,
        paths,
        app_state,
        catalog,
        prompt,
        startup_options,
        run_observer,
    );
    defer if (outcome.error_info) |*err_info| err_info.deinit(allocator);
    return outcome.response;
}

pub fn runTaskPromptOutcomeWithObserver(
    allocator: std.mem.Allocator,
    paths: *const Paths,
    app_state: *AppState,
    catalog: *models.Catalog,
    prompt: []const u8,
    startup_options: StartupOptions,
    run_observer: ?RunTaskObserver,
) !RunTaskOutcome {
    const trimmed_prompt = std.mem.trim(u8, prompt, " \t\r\n");
    if (trimmed_prompt.len == 0) {
        return .{
            .response = try allocator.dupe(u8, ""),
            .error_info = null,
        };
    }

    var app: App = .{
        .allocator = allocator,
        .paths = paths,
        .app_state = app_state,
        .catalog = catalog,
        .headless = true,
        .run_observer = run_observer,
        .notice = try allocator.dupe(u8, "Running non-interactive task..."),
    };
    defer app.deinit();
    if (startup_options.openai_auth_mode) |auth_mode| {
        app.openai_auth_mode = auth_mode;
    }
    if (startup_options.auto_compact_percent_left) |percent_left| {
        app.auto_compact_percent_left = normalizeAutoCompactPercentLeft(percent_left);
    }
    app.ensureCurrentConversationVisibleInStrip();

    try app.handlePrompt(trimmed_prompt);
    const final = try app.latestAssistantResponseAlloc();
    errdefer allocator.free(final);
    try app.emitRunTaskEvent(.{ .final = final });
    var outcome: RunTaskOutcome = .{
        .response = final,
        .error_info = null,
    };
    if (app.last_run_error) |err_info| {
        outcome.error_info = .{
            .code = try allocator.dupe(u8, err_info.code),
            .message = try allocator.dupe(u8, err_info.message),
            .retryable = err_info.retryable,
            .source = try allocator.dupe(u8, err_info.source),
        };
    }
    return outcome;
}

fn suspendForJobControl(raw_mode: *RawMode, app: *App) !void {
    app.suspend_requested = false;
    app.stream_stop_for_suspend = false;

    raw_mode.disable();
    try std.posix.raise(std.posix.SIG.TSTP);
    raw_mode.* = try RawMode.enable();

    try app.setNotice("Resumed (fg)");
    if (!app.should_exit) {
        try app.render();
    }
}

fn mapEscapeSequenceToKey() !?u8 {
    if (!try stdinHasPendingByte(2)) return null;

    var second: [1]u8 = undefined;
    const second_read = try std.posix.read(std.fs.File.stdin().handle, second[0..]);
    if (second_read == 0) return null;
    if (second[0] != '[' and second[0] != 'O') return null;

    if (!try stdinHasPendingByte(2)) return null;

    var third: [1]u8 = undefined;
    const third_read = try std.posix.read(std.fs.File.stdin().handle, third[0..]);
    if (third_read == 0) return null;

    switch (third[0]) {
        'A' => return KEY_UP_ARROW,
        'B' => return KEY_DOWN_ARROW,
        '5', '6' => {
            if (second[0] != '[') return null;
            if (!try stdinHasPendingByte(2)) return null;

            var fourth: [1]u8 = undefined;
            const fourth_read = try std.posix.read(std.fs.File.stdin().handle, fourth[0..]);
            if (fourth_read == 0 or fourth[0] != '~') return null;

            return if (third[0] == '5') KEY_PAGE_UP else KEY_PAGE_DOWN;
        },
        else => return null,
    }
}

fn stdinHasPendingByte(timeout_ms: i32) !bool {
    var poll_fds = [_]std.posix.pollfd{.{
        .fd = std.fs.File.stdin().handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready_count = try std.posix.poll(&poll_fds, timeout_ms);
    return ready_count > 0 and (poll_fds[0].revents & std.posix.POLL.IN) == std.posix.POLL.IN;
}

const App = struct {
    allocator: std.mem.Allocator,
    paths: *const Paths,
    app_state: *AppState,
    catalog: *models.Catalog,

    mode: Mode = .normal,
    should_exit: bool = false,
    is_streaming: bool = false,

    input_buffer: std.ArrayList(u8) = .empty,
    input_cursor: usize = 0,
    scroll_lines: usize = 0,
    conv_strip_start: usize = 0,
    model_picker_open: bool = false,
    model_picker_index: usize = 0,
    model_picker_scroll: usize = 0,
    command_picker_open: bool = false,
    command_picker_kind: CommandPickerKind = .slash_commands,
    command_picker_index: usize = 0,
    command_picker_scroll: usize = 0,
    file_picker_open: bool = false,
    file_picker_index: usize = 0,
    file_picker_scroll: usize = 0,
    file_index: std.ArrayList([]u8) = .empty,
    file_index_attempted: bool = false,
    file_index_loaded: bool = false,
    skills_loaded: bool = false,
    skills: std.ArrayList(SkillInfo) = .empty,
    command_sessions: std.ArrayList(*CommandSession) = .empty,
    next_command_session_id: u32 = 1,
    compact_mode: bool = true,
    theme: Theme = .codex,
    keybindings: Keybindings = .{},
    stream_interrupt_esc_count: u8 = 0,
    stream_interrupt_last_esc_ms: i64 = 0,
    stream_interrupt_hint_shown: bool = false,
    stream_was_interrupted: bool = false,
    stream_stop_for_suspend: bool = false,
    stream_started_ms: i64 = 0,
    stream_task: StreamTask = .idle,
    suspend_requested: bool = false,
    headless: bool = false,
    auto_compact_enabled: bool = true,
    auto_compact_percent_left: i64 = AUTO_COMPACT_PERCENT_LEFT_THRESHOLD,
    openai_auth_mode: OpenAiAuthMode = .auto,
    agents_context_initialized: bool = false,
    agents_context_payload: ?[]u8 = null,
    last_run_error: ?RunTaskErrorInfo = null,
    last_successful_tool_call: ?[]u8 = null,
    last_successful_tool_result_summary: ?[]u8 = null,
    run_observer: ?RunTaskObserver = null,

    notice: []u8,

    pub fn deinit(self: *App) void {
        for (self.command_sessions.items) |session| {
            self.cleanupCommandSession(session);
            self.allocator.destroy(session);
        }
        self.command_sessions.deinit(self.allocator);
        self.input_buffer.deinit(self.allocator);
        for (self.file_index.items) |path| self.allocator.free(path);
        self.file_index.deinit(self.allocator);
        for (self.skills.items) |*skill| skill.deinit(self.allocator);
        self.skills.deinit(self.allocator);
        if (self.agents_context_payload) |payload| self.allocator.free(payload);
        if (self.last_run_error) |*err_info| err_info.deinit(self.allocator);
        if (self.last_successful_tool_call) |value| self.allocator.free(value);
        if (self.last_successful_tool_result_summary) |value| self.allocator.free(value);
        self.allocator.free(self.notice);
    }

    fn emitRunTaskEvent(self: *App, event: RunTaskEvent) !void {
        if (!self.headless) return;
        const observer = self.run_observer orelse return;
        try observer.on_event(observer.context, event);
    }

    fn handleByte(self: *App, key_byte: u8) !void {
        if (key_byte == 3) {
            self.should_exit = true;
            return;
        }

        switch (self.mode) {
            .normal => try self.handleNormalByte(key_byte),
            .insert => try self.handleInsertByte(key_byte),
        }
    }

    fn handleNormalByte(self: *App, key_byte: u8) !void {
        if (key_byte == self.keybindings.normal.quit) {
            self.should_exit = true;
            return;
        }
        if (key_byte == self.keybindings.normal.insert_mode) {
            self.mode = .insert;
            self.syncPickersFromInput();
            return;
        }
        if (key_byte == self.keybindings.normal.append_mode) {
            if (self.input_cursor < self.input_buffer.items.len) self.input_cursor += 1;
            self.mode = .insert;
            self.syncPickersFromInput();
            return;
        }
        if (key_byte == self.keybindings.normal.cursor_left) {
            if (self.input_cursor > 0) self.input_cursor -= 1;
            return;
        }
        if (key_byte == self.keybindings.normal.cursor_right) {
            if (self.input_cursor < self.input_buffer.items.len) self.input_cursor += 1;
            return;
        }
        if (key_byte == self.keybindings.normal.delete_char) {
            if (self.input_cursor < self.input_buffer.items.len) _ = self.input_buffer.orderedRemove(self.input_cursor);
            return;
        }
        if (key_byte == self.keybindings.normal.scroll_up) {
            self.scroll_lines +|= 1;
            return;
        }
        if (key_byte == self.keybindings.normal.scroll_down) {
            if (self.scroll_lines > 0) self.scroll_lines -= 1;
            return;
        }
        if (key_byte == self.keybindings.normal.strip_left) {
            self.shiftConversationStrip(-1);
            return;
        }
        if (key_byte == self.keybindings.normal.strip_right) {
            self.shiftConversationStrip(1);
            return;
        }
        if (key_byte == self.keybindings.normal.command_palette) {
            try self.openCommandPalette();
            return;
        }
        if (key_byte == self.keybindings.normal.slash_command) {
            self.mode = .insert;
            if (self.input_buffer.items.len == 0) {
                try self.input_buffer.append(self.allocator, '/');
                self.input_cursor = 1;
            }
            self.syncPickersFromInput();
            return;
        }

        switch (key_byte) {
            KEY_PAGE_UP => self.scrollPageUp(),
            KEY_PAGE_DOWN => self.scrollPageDown(),
            27 => self.mode = .normal,
            else => {},
        }
    }

    fn handleInsertByte(self: *App, key_byte: u8) !void {
        if (key_byte == self.keybindings.insert.escape) {
            if (self.model_picker_open) {
                self.model_picker_open = false;
                return;
            }
            if (self.command_picker_open) {
                self.command_picker_open = false;
                return;
            }
            if (self.file_picker_open) {
                self.file_picker_open = false;
                return;
            }
            self.mode = .normal;
            return;
        }

        if (key_byte == self.keybindings.insert.backspace) {
            if (self.input_cursor > 0) {
                self.input_cursor -= 1;
                _ = self.input_buffer.orderedRemove(self.input_cursor);
            }
            self.syncPickersFromInput();
            return;
        }

        if (keyMatchesSubmit(self.keybindings.insert.submit, key_byte)) {
            if (self.model_picker_open) {
                try self.acceptModelPickerSelection();
                return;
            }
            if (self.command_picker_open) {
                try self.acceptCommandPickerSelection();
                return;
            }
            if (self.file_picker_open) {
                try self.acceptFilePickerSelection();
                return;
            }
            try self.submitInput();
            return;
        }

        if (key_byte == self.keybindings.insert.accept_picker) {
            if (self.model_picker_open) {
                try self.acceptModelPickerSelection();
                return;
            }
            if (self.command_picker_open) {
                try self.acceptCommandPickerSelection();
                return;
            }
            if (self.file_picker_open) {
                try self.acceptFilePickerSelection();
                return;
            }
            return;
        }

        if (key_byte == self.keybindings.insert.picker_next) {
            _ = self.moveActivePickerSelection(1);
            return;
        }
        if (key_byte == self.keybindings.insert.picker_prev_or_palette) {
            if (!self.moveActivePickerSelection(-1)) {
                try self.openCommandPalette();
            }
            return;
        }
        if (key_byte == self.keybindings.insert.paste_image) {
            try self.pasteClipboardImageIntoInput();
            return;
        }

        switch (key_byte) {
            KEY_PAGE_UP => self.scrollPageUp(),
            KEY_PAGE_DOWN => self.scrollPageDown(),
            KEY_DOWN_ARROW => _ = self.moveActivePickerSelection(1),
            KEY_UP_ARROW => _ = self.moveActivePickerSelection(-1),
            else => {
                if (key_byte >= 32 and key_byte <= 126) {
                    try self.input_buffer.insert(self.allocator, self.input_cursor, key_byte);
                    self.input_cursor += 1;
                    self.syncPickersFromInput();
                }
            },
        }
    }

    fn keyMatchesSubmit(submit_key: u8, key_byte: u8) bool {
        if (submit_key == '\n' or submit_key == '\r') {
            return key_byte == '\n' or key_byte == '\r';
        }
        return key_byte == submit_key;
    }

    fn scrollPageUp(self: *App) void {
        self.scroll_lines +|= self.chatPageScrollStep();
    }

    fn scrollPageDown(self: *App) void {
        self.scroll_lines -|= self.chatPageScrollStep();
    }

    fn chatPageScrollStep(self: *App) usize {
        const viewport_height = self.chatViewportHeight();
        return if (viewport_height > 1) viewport_height - 1 else 1;
    }

    fn chatViewportHeight(self: *App) usize {
        const metrics = self.terminalMetrics();
        const top_lines: usize = if (self.compact_mode) 2 else 4;
        const picker_lines = self.pickerLineCount(metrics.lines);
        const bottom_lines: usize = 3 + picker_lines;
        return @max(@as(usize, 4), metrics.lines - top_lines - bottom_lines);
    }

    fn openCommandPalette(self: *App) !void {
        self.mode = .insert;
        try self.setInputBufferTo(">");
        self.command_picker_open = false;
        self.command_picker_index = 0;
        self.command_picker_scroll = 0;
        self.command_picker_kind = .quick_actions;
        self.syncPickersFromInput();
        try self.setNotice("Opened command palette (type to filter)");
    }

    fn openConversationSwitchPicker(self: *App) !void {
        self.mode = .insert;
        try self.setInputBufferTo("/sessions ");
        self.command_picker_open = false;
        self.command_picker_index = 0;
        self.command_picker_scroll = 0;
        self.command_picker_kind = .conversation_switch;
        self.syncPickersFromInput();
        try self.setNotice("Select a conversation session");
    }

    fn setInputBufferTo(self: *App, text: []const u8) !void {
        self.input_buffer.clearRetainingCapacity();
        try self.input_buffer.appendSlice(self.allocator, text);
        self.input_cursor = self.input_buffer.items.len;
    }

    fn shouldAutoTitleCurrentConversation(self: *App) bool {
        const conversation = self.app_state.currentConversationConst();
        if (conversation.messages.items.len != 0) return false;
        if (std.mem.eql(u8, conversation.title, "New conversation")) return true;
        return std.mem.startsWith(u8, conversation.title, "Conversation ");
    }

    fn deriveConversationTitleFromPrompt(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
        const trimmed = std.mem.trim(u8, prompt, " \t\r\n");
        if (trimmed.len == 0) return allocator.dupe(u8, "New conversation");

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        var previous_was_space = false;
        for (trimmed) |byte| {
            const is_space = byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
            if (is_space) {
                if (out.items.len == 0 or previous_was_space) continue;
                try out.append(allocator, ' ');
                previous_was_space = true;
                continue;
            }

            try out.append(allocator, byte);
            previous_was_space = false;
        }

        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
            _ = out.pop();
        }

        if (out.items.len == 0) return allocator.dupe(u8, "New conversation");
        return out.toOwnedSlice(allocator);
    }

    fn moveActivePickerSelection(self: *App, delta: i32) bool {
        if (self.model_picker_open) {
            self.moveModelPickerSelection(delta);
            return true;
        }
        if (self.command_picker_open) {
            self.moveCommandPickerSelection(delta);
            return true;
        }
        if (self.file_picker_open) {
            self.moveFilePickerSelection(delta);
            return true;
        }
        return false;
    }

    fn submitInput(self: *App) !void {
        const trimmed = std.mem.trim(u8, self.input_buffer.items, " \t\r\n");
        const line = try self.allocator.dupe(u8, trimmed);
        defer self.allocator.free(line);

        self.input_buffer.clearRetainingCapacity();
        self.input_cursor = 0;
        self.model_picker_open = false;
        self.command_picker_open = false;
        self.command_picker_kind = .slash_commands;
        self.file_picker_open = false;

        if (line.len == 0) return;

        if (line[0] == '/') {
            self.model_picker_open = false;
            try self.handleCommand(line);
            return;
        }

        try self.handlePrompt(line);
    }

    fn handlePrompt(self: *App, prompt: []const u8) !void {
        const inject_result = try buildFileInjectionPayload(self.allocator, prompt);
        defer if (inject_result.payload) |payload| self.allocator.free(payload);
        const skill_inject_result = try self.buildSkillInjectionPayload(prompt);
        defer if (skill_inject_result.payload) |payload| self.allocator.free(payload);
        self.clearLastRunError();
        self.clearLastSuccessfulTool();

        const provider_id = self.app_state.selected_provider_id;
        const model_id = self.app_state.selected_model_id;
        if (self.selectedModelContextWindow()) |window| {
            self.app_state.currentConversation().model_context_window = window;
        }

        var maybe_auth: ?ResolvedProviderAuth = null;
        defer if (maybe_auth) |*auth| auth.deinit(self.allocator);

        if (self.shouldAutoCompactCurrentConversation()) {
            maybe_auth = try self.resolveProviderAuth(provider_id);
            _ = try self.compactCurrentConversation(
                provider_id,
                model_id,
                if (maybe_auth) |*auth| auth else null,
                .automatic,
                autoCompactPercentLeft(self.app_state.currentConversationConst()),
            );
        }

        const conversation_was_empty = self.app_state.currentConversationConst().messages.items.len == 0;

        if (self.shouldAutoTitleCurrentConversation()) {
            const title = try deriveConversationTitleFromPrompt(self.allocator, prompt);
            defer self.allocator.free(title);
            if (title.len > 0) {
                try self.app_state.setConversationTitle(self.allocator, title);
            }
        }

        if (conversation_was_empty) {
            try self.injectAgentsContextIntoCurrentConversation();
            try self.injectSkillsContextIntoCurrentConversation();
        }

        try self.app_state.appendMessage(self.allocator, .user, prompt);
        if (inject_result.payload) |payload| {
            try self.app_state.appendMessage(self.allocator, .system, payload);
        }
        if (skill_inject_result.payload) |payload| {
            try self.app_state.appendMessage(self.allocator, .system, payload);
        }
        try self.app_state.appendMessage(self.allocator, .assistant, "");

        if (maybe_auth == null) {
            maybe_auth = try self.resolveProviderAuth(provider_id);
        }

        if (maybe_auth == null) {
            if (std.mem.eql(u8, provider_id, "openai")) {
                const message = "[local] Missing OpenAI auth (API key or Codex subscription token).";
                try self.setLastAssistantMessage(message);
                try self.setNotice("Set OPENAI_API_KEY, or login with Codex/OpenCode OAuth (CODEX_HOME/auth.json, ~/.codex/auth.json, or ~/.local/share/opencode/auth.json). Optional: ZOLT_OPENAI_AUTH=codex.");
                try self.setLastRunError("missing_openai_auth", message, false, "local");
            } else {
                const message = "[local] Missing API key for selected provider.";
                try self.setLastAssistantMessage(message);
                try self.setNoticeFmt("Set env var for provider {s} and retry. Example: {s}", .{
                    provider_id,
                    firstEnvVarForProvider(self, provider_id) orelse "<PROVIDER>_API_KEY",
                });
                try self.setLastRunError("missing_api_key", message, false, "local");
            }
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            return;
        }
        const auth = maybe_auth.?;

        self.is_streaming = true;
        self.stream_was_interrupted = false;
        self.stream_stop_for_suspend = false;
        self.stream_started_ms = std.time.milliTimestamp();
        self.stream_task = .thinking;
        self.resetStreamInterruptState();
        defer {
            self.is_streaming = false;
            self.stream_started_ms = 0;
            self.stream_task = .idle;
            self.resetStreamInterruptState();
        }

        if (inject_result.referenced_count > 0 and skill_inject_result.referenced_count > 0) {
            try self.setNoticeFmt(
                "Injected files {d}/{d} (skipped:{d}) + skills {d}/{d} (skipped:{d})",
                .{
                    inject_result.included_count,
                    inject_result.referenced_count,
                    inject_result.skipped_count,
                    skill_inject_result.included_count,
                    skill_inject_result.referenced_count,
                    skill_inject_result.skipped_count,
                },
            );
        } else if (inject_result.referenced_count > 0) {
            try self.setNoticeFmt(
                "Injected {d}/{d} @file refs (skipped:{d})",
                .{
                    inject_result.included_count,
                    inject_result.referenced_count,
                    inject_result.skipped_count,
                },
            );
        } else if (skill_inject_result.referenced_count > 0) {
            try self.setNoticeFmt(
                "Injected {d}/{d} $skills (skipped:{d})",
                .{
                    skill_inject_result.included_count,
                    skill_inject_result.referenced_count,
                    skill_inject_result.skipped_count,
                },
            );
        }

        const ToolLoopGuardReason = enum {
            none,
            repeated_tool_call,
            max_iterations,
        };
        var guard_reason: ToolLoopGuardReason = .none;
        var executed_any_tool = false;
        var step: usize = 0;
        var seen_tool_signatures: std.ArrayList([]u8) = .empty;
        defer {
            for (seen_tool_signatures.items) |signature| self.allocator.free(signature);
            seen_tool_signatures.deinit(self.allocator);
        }

        tool_loop: while (step < TOOL_MAX_STEPS) : (step += 1) {
            const success = try self.streamAssistantOnce(provider_id, model_id, auth, true);
            if (!success) break;

            const assistant_message = self.app_state.currentConversationConst().messages.items[self.app_state.currentConversationConst().messages.items.len - 1];
            const tool_call = parseAssistantToolCall(assistant_message.content) orelse break;
            switch (tool_call) {
                .read => |read_command| {
                    self.stream_task = .running_read;
                    try self.render();
                    const read_command_owned = try self.allocator.dupe(u8, read_command);
                    defer self.allocator.free(read_command_owned);

                    const tool_note = try std.fmt.allocPrint(self.allocator, "[tool] READ {s}", .{read_command_owned});
                    defer self.allocator.free(tool_note);
                    try self.setLastAssistantMessage(tool_note);
                    try self.emitRunTaskEvent(.{ .tool_call = tool_note });

                    const tool_result = try self.runReadToolCommand(read_command_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool(tool_note, tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNoticeFmt("Ran READ command: {s}", .{read_command_owned});
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "READ",
                        read_command_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .list_dir => |list_dir_payload| {
                    self.stream_task = .running_list_dir;
                    try self.render();
                    const payload_owned = try self.allocator.dupe(u8, list_dir_payload);
                    defer self.allocator.free(payload_owned);

                    try self.setLastAssistantMessage("[tool] LIST_DIR");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] LIST_DIR" });

                    const tool_result = try self.runListDirToolPayload(payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] LIST_DIR", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran LIST_DIR tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "LIST_DIR",
                        payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .read_file => |read_file_payload| {
                    self.stream_task = .running_read_file;
                    try self.render();
                    const payload_owned = try self.allocator.dupe(u8, read_file_payload);
                    defer self.allocator.free(payload_owned);

                    try self.setLastAssistantMessage("[tool] READ_FILE");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] READ_FILE" });

                    const tool_result = try self.runReadFileToolPayload(payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] READ_FILE", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran READ_FILE tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "READ_FILE",
                        payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .grep_files => |grep_payload| {
                    self.stream_task = .running_grep_files;
                    try self.render();
                    const payload_owned = try self.allocator.dupe(u8, grep_payload);
                    defer self.allocator.free(payload_owned);

                    try self.setLastAssistantMessage("[tool] GREP_FILES");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] GREP_FILES" });

                    const tool_result = try self.runGrepFilesToolPayload(payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] GREP_FILES", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran GREP_FILES tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "GREP_FILES",
                        payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .project_search => |project_search_payload| {
                    self.stream_task = .running_project_search;
                    try self.render();
                    const payload_owned = try self.allocator.dupe(u8, project_search_payload);
                    defer self.allocator.free(payload_owned);

                    try self.setLastAssistantMessage("[tool] PROJECT_SEARCH");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] PROJECT_SEARCH" });

                    const tool_result = try self.runProjectSearchToolPayload(payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] PROJECT_SEARCH", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran PROJECT_SEARCH tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "PROJECT_SEARCH",
                        payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .apply_patch => |patch_text| {
                    self.stream_task = .running_apply_patch;
                    try self.render();
                    const patch_text_owned = try self.allocator.dupe(u8, patch_text);
                    defer self.allocator.free(patch_text_owned);

                    try self.setLastAssistantMessage("[tool] APPLY_PATCH");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] APPLY_PATCH" });

                    const tool_result = try self.runApplyPatchToolPatch(patch_text_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] APPLY_PATCH", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran APPLY_PATCH tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "APPLY_PATCH",
                        patch_text_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .exec_command => |exec_payload| {
                    self.stream_task = .running_exec_command;
                    try self.render();
                    const exec_payload_owned = try self.allocator.dupe(u8, exec_payload);
                    defer self.allocator.free(exec_payload_owned);

                    try self.setLastAssistantMessage("[tool] EXEC_COMMAND");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] EXEC_COMMAND" });

                    const tool_result = try self.runExecCommandToolPayload(exec_payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] EXEC_COMMAND", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran EXEC_COMMAND tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "EXEC_COMMAND",
                        exec_payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .write_stdin => |write_payload| {
                    self.stream_task = .running_write_stdin;
                    try self.render();
                    const write_payload_owned = try self.allocator.dupe(u8, write_payload);
                    defer self.allocator.free(write_payload_owned);

                    try self.setLastAssistantMessage("[tool] WRITE_STDIN");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] WRITE_STDIN" });

                    const tool_result = try self.runWriteStdinToolPayload(write_payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] WRITE_STDIN", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran WRITE_STDIN tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "WRITE_STDIN",
                        write_payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .web_search => |web_search_payload| {
                    self.stream_task = .running_web_search;
                    try self.render();
                    const web_search_payload_owned = try self.allocator.dupe(u8, web_search_payload);
                    defer self.allocator.free(web_search_payload_owned);

                    try self.setLastAssistantMessage("[tool] WEB_SEARCH");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] WEB_SEARCH" });

                    const tool_result = try self.runWebSearchToolPayload(web_search_payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] WEB_SEARCH", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran WEB_SEARCH tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "WEB_SEARCH",
                        web_search_payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .view_image => |view_image_payload| {
                    self.stream_task = .running_view_image;
                    try self.render();
                    const view_image_payload_owned = try self.allocator.dupe(u8, view_image_payload);
                    defer self.allocator.free(view_image_payload_owned);

                    try self.setLastAssistantMessage("[tool] VIEW_IMAGE");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] VIEW_IMAGE" });

                    const tool_result = try self.runViewImageToolPayload(view_image_payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] VIEW_IMAGE", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran VIEW_IMAGE tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "VIEW_IMAGE",
                        view_image_payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
                .skill => |skill_payload| {
                    self.stream_task = .running_skill;
                    try self.render();
                    const skill_payload_owned = try self.allocator.dupe(u8, skill_payload);
                    defer self.allocator.free(skill_payload_owned);

                    try self.setLastAssistantMessage("[tool] SKILL");
                    try self.emitRunTaskEvent(.{ .tool_call = "[tool] SKILL" });

                    const tool_result = try self.runSkillToolPayload(skill_payload_owned);
                    defer self.allocator.free(tool_result);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_result });
                    try self.recordSuccessfulTool("[tool] SKILL", tool_result);
                    try self.app_state.appendMessage(self.allocator, .system, tool_result);
                    try self.app_state.appendMessage(self.allocator, .assistant, "");
                    try self.setNotice("Ran SKILL tool");
                    executed_any_tool = true;
                    if (try didRepeatToolExecution(
                        self.allocator,
                        &seen_tool_signatures,
                        "SKILL",
                        skill_payload_owned,
                        tool_result,
                    )) {
                        guard_reason = .repeated_tool_call;
                        break :tool_loop;
                    }
                },
            }
            self.stream_task = .thinking;
            try self.render();
        }

        const conversation_after_loop = self.app_state.currentConversationConst();
        const last_is_tool_marker = if (conversation_after_loop.messages.items.len > 0) blk: {
            const last_message = conversation_after_loop.messages.items[conversation_after_loop.messages.items.len - 1];
            break :blk parseAssistantToolCall(last_message.content) != null;
        } else false;

        if (guard_reason == .none and step == TOOL_MAX_STEPS and last_is_tool_marker and !self.stream_was_interrupted) {
            guard_reason = .max_iterations;
        }

        if (!self.stream_was_interrupted and provider_client.lastProviderErrorDetail() == null and executed_any_tool) {
            const force_summary_instruction = switch (guard_reason) {
                .none => "[tool-result]\nTool execution completed. Provide a final user-facing answer now. Do not call more tools.",
                .repeated_tool_call => "[tool-result]\nA repeated tool-call loop was detected. Stop calling tools and provide a final user-facing answer now.",
                .max_iterations => "[tool-result]\nTool iteration limit was reached. Stop calling tools and provide a final user-facing answer now.",
            };
            try self.app_state.appendMessage(self.allocator, .system, force_summary_instruction);
            try self.app_state.appendMessage(self.allocator, .assistant, "");
            _ = try self.streamAssistantOnce(provider_id, model_id, auth, false);
        }

        if (!self.stream_was_interrupted and provider_client.lastProviderErrorDetail() == null) {
            switch (guard_reason) {
                .none => try self.ensureLastAssistantUserFacing(),
                .repeated_tool_call => {
                    const fallback = try self.buildToolFallbackSummaryAlloc("repeated_tool_call");
                    defer self.allocator.free(fallback);
                    try self.setLastAssistantMessage(fallback);
                    try self.setNotice("Stopped repeated tool loop; synthesized fallback summary.");
                },
                .max_iterations => {
                    const fallback = try self.buildToolFallbackSummaryAlloc("max_tool_iterations");
                    defer self.allocator.free(fallback);
                    try self.setLastAssistantMessage(fallback);
                    try self.setNotice("Tool step limit reached; synthesized fallback summary.");
                },
            }
        }
        if (!self.stream_was_interrupted and provider_client.lastProviderErrorDetail() == null) {
            try self.setNoticeFmt("Completed response from {s}/{s}", .{ provider_id, model_id });
        }
        try self.app_state.saveToPath(self.allocator, self.paths.state_path);
    }

    const CompactionMode = enum {
        manual,
        automatic,
    };

    const CompactionSummaryKind = enum {
        model,
        local_fallback,
    };

    const CompactionTokenCollector = struct {
        allocator: std.mem.Allocator,
        output: std.ArrayList(u8) = .empty,

        fn deinit(self: *CompactionTokenCollector) void {
            self.output.deinit(self.allocator);
        }
    };

    fn shouldAutoCompactCurrentConversation(self: *App) bool {
        if (!self.auto_compact_enabled) return false;
        const conversation = self.app_state.currentConversationConst();
        if (conversation.messages.items.len < AUTO_COMPACT_MIN_MESSAGES) return false;
        const percent_left = autoCompactPercentLeft(conversation) orelse return false;
        return percent_left <= self.auto_compact_percent_left;
    }

    fn compactCurrentConversation(
        self: *App,
        provider_id: []const u8,
        model_id: []const u8,
        auth: ?*const ResolvedProviderAuth,
        mode: CompactionMode,
        trigger_percent_left: ?i64,
    ) !bool {
        var conversation = self.app_state.currentConversation();
        const total_messages = conversation.messages.items.len;
        if (total_messages <= COMPACT_KEEP_RECENT_MESSAGES) return false;

        const tail_start = total_messages - COMPACT_KEEP_RECENT_MESSAGES;
        const source_count = countCompactionSourceMessages(conversation.messages.items[0..tail_start]);
        if (source_count < COMPACT_MIN_SOURCE_MESSAGES) return false;

        const previous_streaming = self.is_streaming;
        const previous_started_ms = self.stream_started_ms;
        const previous_stream_task = self.stream_task;
        if (!self.headless) {
            self.is_streaming = true;
            self.stream_started_ms = std.time.milliTimestamp();
            self.stream_task = .compacting;
            if (mode == .automatic) {
                try self.setNotice("Auto compacting conversation...");
            } else {
                try self.setNotice("Compacting conversation...");
            }
            try self.render();
        }
        defer {
            if (!self.headless) {
                self.is_streaming = previous_streaming;
                self.stream_started_ms = previous_started_ms;
                self.stream_task = previous_stream_task;
            }
        }

        var summary_kind: CompactionSummaryKind = .local_fallback;
        const summary = try self.buildCompactionSummaryAlloc(
            provider_id,
            model_id,
            auth,
            conversation,
            tail_start,
            &summary_kind,
        );
        defer self.allocator.free(summary);

        try self.applyConversationCompaction(summary, summary_kind, tail_start, mode, trigger_percent_left);
        return true;
    }

    fn buildCompactionSummaryAlloc(
        self: *App,
        provider_id: []const u8,
        model_id: []const u8,
        auth: ?*const ResolvedProviderAuth,
        conversation: *const Conversation,
        tail_start: usize,
        out_kind: *CompactionSummaryKind,
    ) ![]u8 {
        if (auth) |resolved_auth| {
            if (try self.buildModelCompactionSummaryAlloc(provider_id, model_id, resolved_auth, conversation, tail_start)) |summary| {
                out_kind.* = .model;
                return summary;
            }
        }

        out_kind.* = .local_fallback;
        return self.buildLocalCompactionSummaryAlloc(conversation, tail_start);
    }

    fn buildModelCompactionSummaryAlloc(
        self: *App,
        provider_id: []const u8,
        model_id: []const u8,
        auth: *const ResolvedProviderAuth,
        conversation: *const Conversation,
        tail_start: usize,
    ) !?[]u8 {
        const provider_info = self.catalog.findProviderConst(provider_id);
        const request_messages = try self.buildCompactionRequestMessages(conversation, tail_start);
        defer self.allocator.free(request_messages);

        var collector: CompactionTokenCollector = .{
            .allocator = self.allocator,
            .output = .empty,
        };
        defer collector.deinit();

        provider_client.streamChat(self.allocator, .{
            .provider_id = provider_id,
            .model_id = model_id,
            .api_key = auth.bearer_token,
            .base_url = auth.base_url_override orelse if (provider_info) |info| info.api_base else null,
            .chatgpt_account_id = auth.chatgpt_account_id,
            .prefer_responses_api = auth.prefer_responses_api,
            .messages = request_messages,
        }, .{
            .on_token = onCompactionSummaryToken,
            .context = &collector,
        }) catch return null;

        if (collector.output.items.len == 0) return null;
        const raw = try collector.output.toOwnedSlice(self.allocator);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            self.allocator.free(raw);
            return null;
        }
        if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) return raw;

        const owned_trimmed = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(raw);
        return owned_trimmed;
    }

    fn onCompactionSummaryToken(context: ?*anyopaque, token: []const u8) anyerror!void {
        const collector: *CompactionTokenCollector = @ptrCast(@alignCast(context.?));
        if (token.len == 0) return;
        try collector.output.appendSlice(collector.allocator, token);
    }

    fn buildCompactionRequestMessages(
        self: *App,
        conversation: *const Conversation,
        tail_start: usize,
    ) ![]provider_client.StreamMessage {
        const source_slice = conversation.messages.items[0..tail_start];
        const source_count = countCompactionSourceMessages(source_slice);
        var messages = try self.allocator.alloc(provider_client.StreamMessage, source_count + 2);

        var index: usize = 0;
        messages[index] = .{
            .role = .system,
            .content = COMPACT_SUMMARY_SYSTEM_PROMPT,
        };
        index += 1;

        for (source_slice) |message| {
            if (!isCompactionSourceMessage(message)) continue;
            messages[index] = .{
                .role = message.role,
                .content = message.content,
            };
            index += 1;
        }

        messages[index] = .{
            .role = .user,
            .content = COMPACT_SUMMARY_USER_PROMPT,
        };
        index += 1;

        return messages[0..index];
    }

    fn buildLocalCompactionSummaryAlloc(self: *App, conversation: *const Conversation, tail_start: usize) ![]u8 {
        var selected_indexes: std.ArrayList(usize) = .empty;
        defer selected_indexes.deinit(self.allocator);

        var index = tail_start;
        while (index > 0 and selected_indexes.items.len < COMPACT_LOCAL_FALLBACK_MAX_LINES) {
            index -= 1;
            const message = conversation.messages.items[index];
            if (!isCompactionSourceMessage(message)) continue;
            try selected_indexes.append(self.allocator, index);
        }

        var summary_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer summary_writer.deinit();
        try summary_writer.writer.writeAll("Local fallback summary:\n");

        if (selected_indexes.items.len == 0) {
            try summary_writer.writer.writeAll("- Prior discussion exists; keep recent messages and continue.\n");
        } else {
            var reverse = selected_indexes.items.len;
            while (reverse > 0) {
                reverse -= 1;
                const message = conversation.messages.items[selected_indexes.items[reverse]];
                const preview = try compactPreviewAlloc(self.allocator, message.content, COMPACT_LOCAL_FALLBACK_PREVIEW_CHARS);
                defer self.allocator.free(preview);
                try summary_writer.writer.print(
                    "- {s}: {s}\n",
                    .{ roleLabelForCompact(message.role), preview },
                );
            }
        }

        return summary_writer.toOwnedSlice();
    }

    fn applyConversationCompaction(
        self: *App,
        summary: []const u8,
        summary_kind: CompactionSummaryKind,
        tail_start: usize,
        mode: CompactionMode,
        trigger_percent_left: ?i64,
    ) !void {
        var conversation = self.app_state.currentConversation();
        var compacted_messages: std.ArrayList(Message) = .empty;
        errdefer {
            for (compacted_messages.items) |*message| message.deinit(self.allocator);
            compacted_messages.deinit(self.allocator);
        }

        const now_ms = std.time.milliTimestamp();
        const old_messages = conversation.messages.items;
        const preserve_agents_context = old_messages.len > 0 and
            old_messages[0].role == .system and
            std.mem.startsWith(u8, old_messages[0].content, AGENTS_CONTEXT_HEADER);

        if (preserve_agents_context) {
            try appendCompactedMessageCopy(self.allocator, &compacted_messages, old_messages[0]);
        }

        const note_text = switch (mode) {
            .manual => try std.fmt.allocPrint(
                self.allocator,
                "{s} manual ({s} summary)",
                .{ COMPACT_NOTE_HEADER, if (summary_kind == .model) "model" else "local fallback" },
            ),
            .automatic => if (trigger_percent_left) |percent_left|
                try std.fmt.allocPrint(
                    self.allocator,
                    "{s} auto at {d}% left ({s} summary)",
                    .{ COMPACT_NOTE_HEADER, percent_left, if (summary_kind == .model) "model" else "local fallback" },
                )
            else
                try std.fmt.allocPrint(
                    self.allocator,
                    "{s} auto ({s} summary)",
                    .{ COMPACT_NOTE_HEADER, if (summary_kind == .model) "model" else "local fallback" },
                ),
        };
        defer self.allocator.free(note_text);
        try appendCompactedMessageOwned(self.allocator, &compacted_messages, .system, note_text, now_ms);

        const summary_payload = try std.fmt.allocPrint(
            self.allocator,
            "{s}\n{s}",
            .{ COMPACT_SUMMARY_HEADER, summary },
        );
        defer self.allocator.free(summary_payload);
        try appendCompactedMessageOwned(self.allocator, &compacted_messages, .system, summary_payload, now_ms);

        for (old_messages[tail_start..], tail_start..) |message, old_index| {
            if (preserve_agents_context and old_index == 0) continue;
            try appendCompactedMessageCopy(self.allocator, &compacted_messages, message);
        }

        for (conversation.messages.items) |*message| message.deinit(self.allocator);
        conversation.messages.deinit(self.allocator);
        conversation.messages = compacted_messages;
        conversation.last_token_usage = .{};
        conversation.updated_ms = now_ms;

        switch (mode) {
            .manual => try self.setNoticeFmt(
                "Compacted conversation (kept last {d} messages, {s} summary)",
                .{ COMPACT_KEEP_RECENT_MESSAGES, if (summary_kind == .model) "model" else "local fallback" },
            ),
            .automatic => try self.setNoticeFmt(
                "Auto compacted conversation (kept last {d} messages, {s} summary)",
                .{ COMPACT_KEEP_RECENT_MESSAGES, if (summary_kind == .model) "model" else "local fallback" },
            ),
        }
    }

    fn streamAssistantOnce(self: *App, provider_id: []const u8, model_id: []const u8, auth: ResolvedProviderAuth, include_tool_prompt: bool) !bool {
        const provider_info = self.catalog.findProviderConst(provider_id);
        const request: provider_client.StreamRequest = .{
            .provider_id = provider_id,
            .model_id = model_id,
            .api_key = auth.bearer_token,
            .base_url = auth.base_url_override orelse if (provider_info) |info| info.api_base else null,
            .chatgpt_account_id = auth.chatgpt_account_id,
            .prefer_responses_api = auth.prefer_responses_api,
            .messages = try self.buildStreamMessages(include_tool_prompt),
        };
        defer self.allocator.free(request.messages);

        self.stream_task = .thinking;
        try self.setNoticeFmt("Streaming from {s}/{s}...", .{ provider_id, model_id });
        try self.render();

        var attempt: usize = 0;
        var auth_for_retry = auth;
        while (true) {
            provider_client.streamChat(self.allocator, request, .{
                .on_token = onStreamToken,
                .on_usage = onStreamUsage,
                .context = self,
            }) catch |err| {
                if (err == error.StreamInterrupted) {
                    self.stream_was_interrupted = true;
                    if (self.stream_stop_for_suspend) {
                        try self.setNotice("Suspending... use fg to resume");
                    } else {
                        try self.appendInterruptedMessage();
                        try self.setNotice("Streaming interrupted (Esc Esc)");
                    }
                    try self.app_state.saveToPath(self.allocator, self.paths.state_path);
                    return false;
                }

                const provider_detail = provider_client.lastProviderErrorDetail();
                const failure = try classifyStreamFailureAlloc(self.allocator, err, provider_detail);
                defer {
                    self.allocator.free(failure.code);
                    self.allocator.free(failure.message);
                    self.allocator.free(failure.source);
                }

                if (shouldRetryStreamFailure(failure, attempt)) {
                    if (failure.context_related and self.auto_compact_enabled) {
                        _ = self.compactCurrentConversation(
                            provider_id,
                            model_id,
                            &auth_for_retry,
                            .automatic,
                            autoCompactPercentLeft(self.app_state.currentConversationConst()),
                        ) catch false;
                    }
                    attempt += 1;
                    try self.setNoticeFmt("Retrying request once (reason:{s})...", .{failure.code});
                    try self.render();
                    continue;
                }

                var failure_message = try self.allocator.dupe(u8, failure.message);
                defer self.allocator.free(failure_message);
                if (self.last_successful_tool_call) |tool_call| {
                    const tool_summary = self.last_successful_tool_result_summary orelse "(no summary)";
                    const enriched_failure_message = try std.fmt.allocPrint(
                        self.allocator,
                        "{s}; after successful {s} ({s})",
                        .{ failure.message, tool_call, tool_summary },
                    );
                    self.allocator.free(failure_message);
                    failure_message = enriched_failure_message;

                    const tool_context_note = try std.fmt.allocPrint(
                        self.allocator,
                        "[tool-failure-context] last_successful_tool_call:{s} result:{s}",
                        .{ tool_call, tool_summary },
                    );
                    defer self.allocator.free(tool_context_note);
                    try self.emitRunTaskEvent(.{ .tool_result = tool_context_note });
                }

                try self.setNoticeFmt("Provider request failed: {s}", .{failure_message});
                try self.setLastRunError(failure.code, failure_message, failure.retryable, failure.source);

                const conversation = self.app_state.currentConversationConst();
                const needs_paragraph_break = if (conversation.messages.items.len == 0) false else blk: {
                    const last = conversation.messages.items[conversation.messages.items.len - 1];
                    break :blk last.content.len > 0;
                };
                const failure_line = try std.fmt.allocPrint(
                    self.allocator,
                    "[local] Request failed ({s}): {s}.",
                    .{ failure.code, failure_message },
                );
                defer self.allocator.free(failure_line);
                try self.appendToLastAssistantMessage(if (needs_paragraph_break) "\n\n" else "");
                try self.appendToLastAssistantMessage(failure_line);
                try self.app_state.saveToPath(self.allocator, self.paths.state_path);
                return false;
            };

            self.clearLastRunError();
            return true;
        }
    }

    fn appendInterruptedMessage(self: *App) !void {
        const conversation = self.app_state.currentConversationConst();
        if (conversation.messages.items.len == 0) return;

        const last = conversation.messages.items[conversation.messages.items.len - 1];
        const needs_paragraph_break = last.role == .assistant and last.content.len > 0;
        if (needs_paragraph_break) {
            try self.appendToLastAssistantMessage("\n\n");
        }
        try self.appendToLastAssistantMessage("[local] Generation interrupted by user (Esc Esc).");
    }

    fn buildStreamMessages(self: *App, include_tool_prompt: bool) ![]provider_client.StreamMessage {
        const conversation = self.app_state.currentConversationConst();
        const conversation_len = conversation.messages.items.len;
        const skip_last_empty_assistant = conversation_len > 0 and
            conversation.messages.items[conversation_len - 1].role == .assistant and
            conversation.messages.items[conversation_len - 1].content.len == 0;

        const visible_count = if (skip_last_empty_assistant) conversation_len - 1 else conversation_len;
        const prompt_count: usize = if (include_tool_prompt) 1 else 0;
        const messages = try self.allocator.alloc(provider_client.StreamMessage, visible_count + prompt_count);

        var index: usize = 0;
        if (include_tool_prompt) {
            messages[index] = .{
                .role = .system,
                .content = TOOL_SYSTEM_PROMPT,
            };
            index += 1;
        }

        for (conversation.messages.items[0..visible_count]) |message| {
            messages[index] = .{
                .role = message.role,
                .content = message.content,
            };
            index += 1;
        }

        return messages;
    }

    fn injectAgentsContextIntoCurrentConversation(self: *App) !void {
        const conversation = self.app_state.currentConversationConst();
        if (conversation.messages.items.len != 0) return;

        const payload = (try self.ensureAgentsContextPayload()) orelse return;
        try self.app_state.appendMessage(self.allocator, .system, payload);
    }

    fn injectSkillsContextIntoCurrentConversation(self: *App) !void {
        const conversation = self.app_state.currentConversationConst();
        if (conversation.messages.items.len != 0) return;

        try self.ensureSkillsLoaded();
        if (self.skills.items.len == 0) return;

        const payload = try buildSkillsContextPayloadAlloc(self.allocator, self.skills.items);
        defer self.allocator.free(payload);
        try self.app_state.appendMessage(self.allocator, .system, payload);
    }

    fn ensureAgentsContextPayload(self: *App) !?[]const u8 {
        if (self.agents_context_initialized) {
            return if (self.agents_context_payload) |payload| payload else null;
        }
        self.agents_context_initialized = true;

        const agents_path = try findNearestAgentsFilePathAlloc(self.allocator);
        defer if (agents_path) |path| self.allocator.free(path);
        const path = agents_path orelse return null;

        const payload = readAgentsContextPayloadAlloc(self.allocator, path) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        self.agents_context_payload = payload;
        return payload;
    }

    pub fn ensureSkillsLoaded(self: *App) !void {
        if (self.skills_loaded) return;
        self.skills_loaded = true;

        const discovered = try discoverSkillsAlloc(self.allocator);
        self.skills = discovered;
    }

    fn refreshSkills(self: *App) !void {
        for (self.skills.items) |*skill| skill.deinit(self.allocator);
        self.skills.clearRetainingCapacity();
        self.skills_loaded = false;
        try self.ensureSkillsLoaded();
    }

    pub fn findSkillByName(self: *App, name: []const u8) ?*const SkillInfo {
        const trimmed = std.mem.trim(u8, name, " \t\r\n");
        if (trimmed.len == 0) return null;

        for (self.skills.items) |*skill| {
            if (std.ascii.eqlIgnoreCase(skill.name, trimmed)) return skill;
        }
        return null;
    }

    pub fn skillScopeLabel(_: *App, scope: SkillScope) []const u8 {
        return switch (scope) {
            .project => "project",
            .global => "global",
        };
    }

    fn runReadToolCommand(self: *App, command_text: []const u8) ![]u8 {
        return tools_runtime.runReadToolCommand(self, command_text);
    }

    fn runListDirToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runListDirToolPayload(self, payload);
    }

    fn runReadFileToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runReadFileToolPayload(self, payload);
    }

    fn runGrepFilesToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runGrepFilesToolPayload(self, payload);
    }

    fn runProjectSearchToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runProjectSearchToolPayload(self, payload);
    }

    fn runApplyPatchToolPatch(self: *App, patch_text: []const u8) ![]u8 {
        return tools_runtime.runApplyPatchToolPatch(self, patch_text);
    }

    fn runExecCommandToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runExecCommandToolPayload(self, payload);
    }

    fn runWriteStdinToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runWriteStdinToolPayload(self, payload);
    }

    fn runWebSearchToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runWebSearchToolPayload(self, payload);
    }

    fn runViewImageToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runViewImageToolPayload(self, payload);
    }

    fn runSkillToolPayload(self: *App, payload: []const u8) ![]u8 {
        return tools_runtime.runSkillToolPayload(self, payload);
    }

    fn pasteClipboardImageIntoInput(self: *App) !void {
        const capture = captureClipboardImage(self.allocator) catch |err| {
            try self.setNoticeFmt("Clipboard image paste failed: {s}", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(capture.bytes);

        const images_dir = try std.fs.path.join(self.allocator, &.{ self.paths.data_dir, "images" });
        defer self.allocator.free(images_dir);
        try std.fs.cwd().makePath(images_dir);

        const ext = extensionForImageMime(capture.mime);
        const timestamp_ms = @as(u64, @intCast(@max(@as(i64, 0), std.time.milliTimestamp())));
        const filename = try std.fmt.allocPrint(self.allocator, "clipboard-{d}.{s}", .{ timestamp_ms, ext });
        defer self.allocator.free(filename);

        const image_path = try std.fs.path.join(self.allocator, &.{ images_dir, filename });
        defer self.allocator.free(image_path);

        var file = try std.fs.createFileAbsolute(image_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(capture.bytes);

        const rewritten = rewriteInputWithSelectedAtPath(
            self.allocator,
            self.input_buffer.items,
            self.input_cursor,
            image_path,
        ) catch |err| switch (err) {
            error.MissingAtToken => try insertAtPathTokenAtCursor(
                self.allocator,
                self.input_buffer.items,
                self.input_cursor,
                image_path,
            ),
            else => return err,
        };
        defer self.allocator.free(rewritten.text);

        self.input_buffer.clearRetainingCapacity();
        try self.input_buffer.appendSlice(self.allocator, rewritten.text);
        self.input_cursor = rewritten.cursor;
        self.syncPickersFromInput();

        try self.setNoticeFmt("Pasted image from clipboard -> @{s}", .{image_path});
    }

    fn buildSkillInjectionPayload(self: *App, prompt: []const u8) !SkillInjectResult {
        var references = try collectDollarSkillReferences(self.allocator, prompt);
        defer {
            for (references.items) |entry| self.allocator.free(entry);
            references.deinit(self.allocator);
        }

        if (references.items.len == 0) return .{};
        try self.ensureSkillsLoaded();
        if (self.skills.items.len == 0) {
            return .{
                .referenced_count = references.items.len,
                .included_count = 0,
                .skipped_count = references.items.len,
            };
        }

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();
        var included_count: usize = 0;
        var skipped_count: usize = 0;
        var summary_names: std.ArrayList([]const u8) = .empty;
        defer summary_names.deinit(self.allocator);

        for (references.items) |reference| {
            const skill = self.findSkillByName(reference) orelse {
                skipped_count += 1;
                continue;
            };

            var skill_file = openFileForPath(skill.path, .{}) catch {
                skipped_count += 1;
                continue;
            };
            defer skill_file.close();

            const content = skill_file.readToEndAlloc(self.allocator, SKILL_FILE_MAX_BYTES) catch {
                skipped_count += 1;
                continue;
            };
            defer self.allocator.free(content);

            included_count += 1;
            try summary_names.append(self.allocator, skill.name);

            try body_writer.writer.print(
                "<skill name=\"{s}\" path=\"{s}\" scope=\"{s}\" base_dir=\"{s}\">\n",
                .{ skill.name, skill.path, self.skillScopeLabel(skill.scope), skill.base_dir },
            );
            try body_writer.writer.writeAll(content);
            if (content.len == 0 or content[content.len - 1] != '\n') {
                try body_writer.writer.writeByte('\n');
            }
            try body_writer.writer.writeAll("</skill>\n");
        }

        if (included_count == 0) {
            return .{
                .referenced_count = references.items.len,
                .included_count = 0,
                .skipped_count = skipped_count,
            };
        }

        const body = try body_writer.toOwnedSlice();
        defer self.allocator.free(body);

        var payload_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload_writer.deinit();

        try payload_writer.writer.print(
            "{s} included:{d} referenced:{d} skipped:{d}",
            .{ SKILL_INJECT_HEADER, included_count, references.items.len, skipped_count },
        );
        if (summary_names.items.len > 0) {
            try payload_writer.writer.writeAll(" read: ");
            const shown = @min(summary_names.items.len, @as(usize, 3));
            for (summary_names.items[0..shown], 0..) |name, idx| {
                if (idx > 0) try payload_writer.writer.writeAll(", ");
                try payload_writer.writer.writeAll(name);
            }
            if (summary_names.items.len > shown) {
                try payload_writer.writer.print(" (+{d} more)", .{summary_names.items.len - shown});
            }
        }
        try payload_writer.writer.writeByte('\n');
        try payload_writer.writer.writeAll(
            "The user referenced these skills with $name. Treat this as reusable workflow/context guidance.\n",
        );
        try payload_writer.writer.writeAll(body);

        return .{
            .payload = try payload_writer.toOwnedSlice(),
            .referenced_count = references.items.len,
            .included_count = included_count,
            .skipped_count = skipped_count,
        };
    }

    pub fn tryVisionCaptionOpenAiCompatible(
        self: *App,
        image_path: []const u8,
        image_mime: []const u8,
        provider_id: []const u8,
        base_url: []const u8,
        api_key: []const u8,
    ) !VisionCaptionResult {
        var env_model_owned: ?[]u8 = null;
        defer if (env_model_owned) |text| self.allocator.free(text);

        env_model_owned = std.process.getEnvVarOwned(self.allocator, "ZOLT_VISION_MODEL") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };

        const selected_model = self.app_state.selected_model_id;
        const env_model = if (env_model_owned) |text| std.mem.trim(u8, text, " \t\r\n") else "";
        const default_model = defaultVisionModelForProvider(provider_id);

        const candidates = [_][]const u8{
            selected_model,
            env_model,
            default_model,
        };
        var attempted: [3][]const u8 = undefined;
        var attempted_count: usize = 0;

        var last_error_detail: ?[]u8 = null;
        errdefer if (last_error_detail) |detail| self.allocator.free(detail);

        for (candidates) |candidate| {
            if (candidate.len == 0) continue;
            var is_duplicate = false;
            for (attempted[0..attempted_count]) |previous| {
                if (std.mem.eql(u8, previous, candidate)) {
                    is_duplicate = true;
                    break;
                }
            }
            if (is_duplicate) continue;
            attempted[attempted_count] = candidate;
            attempted_count += 1;

            const attempt = try self.requestVisionCaptionOpenAiCompatible(
                image_path,
                image_mime,
                provider_id,
                base_url,
                api_key,
                candidate,
            );
            if (attempt.caption) |caption| {
                if (last_error_detail) |detail| self.allocator.free(detail);
                return .{ .caption = caption };
            }
            if (attempt.error_detail) |detail| {
                if (last_error_detail) |old| self.allocator.free(old);
                last_error_detail = detail;
            }
        }

        return .{ .error_detail = last_error_detail };
    }

    fn requestVisionCaptionOpenAiCompatible(
        self: *App,
        image_path: []const u8,
        image_mime: []const u8,
        provider_id: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_id: []const u8,
    ) !VisionCaptionResult {
        const data_url = loadImageAsDataUrl(self.allocator, image_path, image_mime, IMAGE_VISION_MAX_BYTES) catch |err| switch (err) {
            error.FileTooBig => return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "image too large for vision request (max:{d} bytes)", .{IMAGE_VISION_MAX_BYTES}) },
            else => return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "failed to encode image: {s}", .{@errorName(err)}) },
        };
        defer self.allocator.free(data_url);

        const endpoint = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{trimTrailingSlashLocal(base_url)});
        defer self.allocator.free(endpoint);

        var payload_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer payload_writer.deinit();
        var jw: std.json.Stringify = .{
            .writer = &payload_writer.writer,
        };

        try jw.beginObject();
        try jw.objectField("model");
        try jw.write(model_id);
        try jw.objectField("max_tokens");
        try jw.write(@as(u16, 400));
        try jw.objectField("messages");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write("user");
        try jw.objectField("content");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("text");
        try jw.objectField("text");
        try jw.write(VIEW_IMAGE_VISION_PROMPT);
        try jw.endObject();
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("image_url");
        try jw.objectField("image_url");
        try jw.beginObject();
        try jw.objectField("url");
        try jw.write(data_url);
        try jw.endObject();
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();
        try jw.endArray();
        try jw.endObject();

        const payload = try payload_writer.toOwnedSlice();
        defer self.allocator.free(payload);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
        defer self.allocator.free(auth_header);

        var extra_headers: [2]std.http.Header = .{
            .{ .name = "HTTP-Referer", .value = "https://opencode.ai/" },
            .{ .name = "X-Title", .value = "zolt" },
        };
        const use_referrer_headers = std.mem.eql(u8, provider_id, "openrouter") or
            std.mem.eql(u8, provider_id, "opencode") or
            std.mem.eql(u8, provider_id, "zenmux");

        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        const uri = std.Uri.parse(endpoint) catch {
            return .{ .error_detail = try self.allocator.dupe(u8, "invalid provider endpoint") };
        };
        var req = client.request(.POST, uri, .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = "zolt/0.1" },
            },
            .extra_headers = if (use_referrer_headers) extra_headers[0..] else &.{},
            .keep_alive = false,
        }) catch |err| {
            return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "request build failed: {s}", .{@errorName(err)}) };
        };
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = payload.len };
        var body_writer = req.sendBodyUnflushed(&.{}) catch |err| {
            return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "request send failed: {s}", .{@errorName(err)}) };
        };
        body_writer.writer.writeAll(payload) catch |err| {
            return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "request write failed: {s}", .{@errorName(err)}) };
        };
        body_writer.end() catch |err| {
            return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "request finalize failed: {s}", .{@errorName(err)}) };
        };
        req.connection.?.flush() catch |err| {
            return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "request flush failed: {s}", .{@errorName(err)}) };
        };

        var response = req.receiveHead(&.{}) catch |err| {
            return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "response header failed: {s}", .{@errorName(err)}) };
        };
        const response_body = readHttpResponseBodyAlloc(self.allocator, &response) catch |err| {
            return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "response read failed: {s}", .{@errorName(err)}) };
        };
        defer self.allocator.free(response_body);

        if (response.head.status != .ok) {
            return .{ .error_detail = try formatHttpErrorDetail(self.allocator, response.head.status, response_body) };
        }

        const caption = parseVisionCaptionFromChatCompletionsAlloc(self.allocator, response_body) catch |err| {
            return .{ .error_detail = try std.fmt.allocPrint(self.allocator, "invalid vision response: {s}", .{@errorName(err)}) };
        };
        if (caption == null) {
            return .{ .error_detail = try self.allocator.dupe(u8, "vision response missing caption text") };
        }
        return .{ .caption = caption.? };
    }

    pub fn appendCommandDrainOutput(self: *App, writer: *std.Io.Writer, drained: SessionDrainResult) !void {
        _ = self;
        if (drained.stdout.len > 0) {
            try writer.writeAll("stdout:\n");
            try writer.writeAll(drained.stdout);
            if (drained.stdout[drained.stdout.len - 1] != '\n') try writer.writeByte('\n');
        }

        if (drained.stderr.len > 0) {
            try writer.writeAll("stderr:\n");
            try writer.writeAll(drained.stderr);
            if (drained.stderr[drained.stderr.len - 1] != '\n') try writer.writeByte('\n');
        }

        if (drained.stdout.len == 0 and drained.stderr.len == 0) {
            try writer.writeAll("stdout:\n(no output)\n");
        }

        if (drained.output_limited) {
            try writer.writeAll("note: output truncated by limit\n");
        }
    }

    pub fn appendCommandSessionStateLine(self: *App, writer: *std.Io.Writer, session: *CommandSession) !void {
        _ = self;
        if (session.finished and session.term != null) {
            const term = session.term.?;
            switch (term) {
                .Exited => |code| try writer.print("state: exited:{d}\n", .{code}),
                .Signal => |sig| try writer.print("state: signal:{d}\n", .{sig}),
                .Stopped => |sig| try writer.print("state: stopped:{d}\n", .{sig}),
                .Unknown => |code| try writer.print("state: unknown:{d}\n", .{code}),
            }
            return;
        }
        try writer.writeAll("state: running\n");
    }

    pub fn pruneCommandSessionsForCapacity(self: *App) !void {
        if (self.command_sessions.items.len < COMMAND_TOOL_MAX_SESSIONS) return;

        var index: usize = 0;
        while (index < self.command_sessions.items.len) : (index += 1) {
            const session = self.command_sessions.items[index];
            self.refreshCommandSessionStatus(session);
            if (session.finished) {
                self.destroyCommandSessionAt(index);
                if (self.command_sessions.items.len < COMMAND_TOOL_MAX_SESSIONS) return;
                index -|= 1;
            }
        }

        if (self.command_sessions.items.len >= COMMAND_TOOL_MAX_SESSIONS) {
            self.destroyCommandSessionAt(0);
        }
    }

    pub fn findCommandSessionById(self: *App, session_id: u32) ?*CommandSession {
        for (self.command_sessions.items) |session| {
            if (session.id == session_id) return session;
        }
        return null;
    }

    pub fn startCommandSession(self: *App, command_text: []const u8) !*CommandSession {
        const session = try self.allocator.create(CommandSession);
        errdefer self.allocator.destroy(session);

        session.* = .{
            .id = self.next_command_session_id,
            .command_line = try self.allocator.dupe(u8, command_text),
            .child = undefined,
        };
        errdefer self.allocator.free(session.command_line);

        const argv = [_][]const u8{
            "bash",
            "-lc",
            session.command_line,
        };
        session.child = std.process.Child.init(argv[0..], self.allocator);
        session.child.cwd = ".";
        session.child.stdin_behavior = .Pipe;
        session.child.stdout_behavior = .Pipe;
        session.child.stderr_behavior = .Pipe;

        session.child.spawn() catch |err| {
            self.cleanupCommandSession(session);
            return err;
        };
        session.child.waitForSpawn() catch |err| {
            self.cleanupCommandSession(session);
            return err;
        };

        self.next_command_session_id += 1;
        try self.command_sessions.append(self.allocator, session);
        return session;
    }

    pub fn drainCommandSessionOutput(self: *App, session: *CommandSession, yield_ms: u32) !SessionDrainResult {
        var stdout: std.ArrayList(u8) = .empty;
        defer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        defer stderr.deinit(self.allocator);
        var output_limited = false;

        const started_ms = std.time.milliTimestamp();
        while (true) {
            self.refreshCommandSessionStatus(session);

            var poll_fds: [2]std.posix.pollfd = undefined;
            var fd_kinds: [2]enum { stdout, stderr } = undefined;
            var fd_count: usize = 0;

            if (session.child.stdout) |stdout_file| {
                poll_fds[fd_count] = .{
                    .fd = stdout_file.handle,
                    .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                    .revents = 0,
                };
                fd_kinds[fd_count] = .stdout;
                fd_count += 1;
            }
            if (session.child.stderr) |stderr_file| {
                poll_fds[fd_count] = .{
                    .fd = stderr_file.handle,
                    .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                    .revents = 0,
                };
                fd_kinds[fd_count] = .stderr;
                fd_count += 1;
            }

            const elapsed_ms = @max(@as(i64, 0), std.time.milliTimestamp() - started_ms);
            const remaining_ms_i64 = @as(i64, @intCast(yield_ms)) - elapsed_ms;
            const timeout_ms: i32 = if (remaining_ms_i64 > 0)
                @as(i32, @intCast(@min(remaining_ms_i64, 200)))
            else
                0;

            if (fd_count > 0) {
                const ready = try std.posix.poll(poll_fds[0..fd_count], timeout_ms);
                if (ready > 0) {
                    for (poll_fds[0..fd_count], 0..) |pollfd, index| {
                        if ((pollfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) == 0) continue;
                        switch (fd_kinds[index]) {
                            .stdout => try self.drainCommandPipeChunk(session, .stdout, &stdout, &output_limited),
                            .stderr => try self.drainCommandPipeChunk(session, .stderr, &stderr, &output_limited),
                        }
                    }
                }
            } else if (timeout_ms > 0) {
                std.Thread.sleep(@as(u64, @intCast(timeout_ms)) * std.time.ns_per_ms);
            }

            if (remaining_ms_i64 <= 0) break;
            if (session.finished and session.child.stdout == null and session.child.stderr == null) break;
        }

        self.refreshCommandSessionStatus(session);
        return .{
            .stdout = try stdout.toOwnedSlice(self.allocator),
            .stderr = try stderr.toOwnedSlice(self.allocator),
            .output_limited = output_limited,
        };
    }

    fn drainCommandPipeChunk(
        self: *App,
        session: *CommandSession,
        comptime pipe_kind: enum { stdout, stderr },
        out: *std.ArrayList(u8),
        output_limited: *bool,
    ) !void {
        const file = switch (pipe_kind) {
            .stdout => session.child.stdout orelse return,
            .stderr => session.child.stderr orelse return,
        };

        var buffer: [2048]u8 = undefined;
        const read_len = std.posix.read(file.handle, buffer[0..]) catch |err| switch (err) {
            error.WouldBlock => return,
            error.BrokenPipe => {
                switch (pipe_kind) {
                    .stdout => {
                        session.child.stdout.?.close();
                        session.child.stdout = null;
                    },
                    .stderr => {
                        session.child.stderr.?.close();
                        session.child.stderr = null;
                    },
                }
                return;
            },
            else => return err,
        };

        if (read_len == 0) {
            switch (pipe_kind) {
                .stdout => {
                    session.child.stdout.?.close();
                    session.child.stdout = null;
                },
                .stderr => {
                    session.child.stderr.?.close();
                    session.child.stderr = null;
                },
            }
            return;
        }

        if (out.items.len < COMMAND_TOOL_MAX_OUTPUT_BYTES) {
            const allowed = COMMAND_TOOL_MAX_OUTPUT_BYTES - out.items.len;
            const slice_end = @min(read_len, allowed);
            if (slice_end > 0) {
                try out.appendSlice(self.allocator, buffer[0..slice_end]);
            }
            if (slice_end < read_len) output_limited.* = true;
        } else {
            output_limited.* = true;
        }
    }

    fn refreshCommandSessionStatus(self: *App, session: *CommandSession) void {
        _ = self;
        if (session.finished) return;

        const result = std.posix.waitpid(session.child.id, std.posix.W.NOHANG);
        if (result.pid == 0) return;

        session.finished = true;
        session.term = statusToChildTerm(result.status);
    }

    fn destroyCommandSessionAt(self: *App, index: usize) void {
        const session = self.command_sessions.orderedRemove(index);
        self.cleanupCommandSession(session);
        self.allocator.destroy(session);
    }

    fn cleanupCommandSession(self: *App, session: *CommandSession) void {
        if (!session.finished) {
            _ = session.child.kill() catch {};
            session.finished = true;
        }
        if (session.child.stdin) |stdin_file| {
            stdin_file.close();
            session.child.stdin = null;
        }
        if (session.child.stdout) |stdout_file| {
            stdout_file.close();
            session.child.stdout = null;
        }
        if (session.child.stderr) |stderr_file| {
            stderr_file.close();
            session.child.stderr = null;
        }
        self.allocator.free(session.command_line);
    }

    fn onStreamToken(context: ?*anyopaque, token: []const u8) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context.?));
        if (try self.pollStreamInterrupt()) {
            return error.StreamInterrupted;
        }
        if (token.len == 0) {
            try self.render();
            return;
        }
        self.stream_task = .responding;
        try self.emitRunTaskEvent(.{ .token = token });
        try self.appendToLastAssistantMessage(token);
        try self.render();
    }

    fn onStreamUsage(context: ?*anyopaque, usage: TokenUsage) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context.?));
        self.app_state.appendTokenUsage(usage, self.selectedModelContextWindow());
    }

    fn resetStreamInterruptState(self: *App) void {
        self.stream_interrupt_esc_count = 0;
        self.stream_interrupt_last_esc_ms = 0;
        self.stream_interrupt_hint_shown = false;
    }

    fn pollStreamInterrupt(self: *App) !bool {
        if (self.headless) return false;

        while (try stdinHasPendingByte(0)) {
            var byte_buf: [1]u8 = undefined;
            const read_len = try std.posix.read(std.fs.File.stdin().handle, byte_buf[0..]);
            if (read_len == 0) break;

            if (byte_buf[0] == 26) {
                self.stream_stop_for_suspend = true;
                self.suspend_requested = true;
                return true;
            }

            const now_ms = std.time.milliTimestamp();
            if (registerStreamInterruptByte(
                &self.stream_interrupt_esc_count,
                &self.stream_interrupt_last_esc_ms,
                byte_buf[0],
                now_ms,
            )) {
                return true;
            }

            if (self.stream_interrupt_esc_count == 1 and !self.stream_interrupt_hint_shown) {
                self.stream_interrupt_hint_shown = true;
                try self.setNotice("Press Esc again to stop stream");
            }
        }
        return false;
    }

    fn appendToLastAssistantMessage(self: *App, token: []const u8) !void {
        const conversation = self.app_state.currentConversation();
        if (conversation.messages.items.len == 0) return;

        const message = &conversation.messages.items[conversation.messages.items.len - 1];

        const old_len = message.content.len;
        message.content = try self.allocator.realloc(message.content, old_len + token.len);
        @memcpy(message.content[old_len..], token);
        message.timestamp_ms = std.time.milliTimestamp();
        conversation.updated_ms = message.timestamp_ms;
    }

    fn setLastAssistantMessage(self: *App, text: []const u8) !void {
        const conversation = self.app_state.currentConversation();
        if (conversation.messages.items.len == 0) return;

        const message = &conversation.messages.items[conversation.messages.items.len - 1];
        if (message.role != .assistant) return;

        const replacement = try self.allocator.dupe(u8, text);
        self.allocator.free(message.content);
        message.content = replacement;
        message.timestamp_ms = std.time.milliTimestamp();
        conversation.updated_ms = message.timestamp_ms;
    }

    fn handleCommand(self: *App, line: []const u8) !void {
        var parts = std.mem.tokenizeAny(u8, line[1..], " \t");
        const command = parts.next() orelse {
            try self.setNotice("Empty command. Try /help");
            return;
        };

        if (std.mem.eql(u8, command, "help")) {
            try self.openCommandPalette();
            return;
        }

        if (std.mem.eql(u8, command, "commands")) {
            try self.openCommandPalette();
            return;
        }

        if (std.mem.eql(u8, command, "quit") or std.mem.eql(u8, command, "q")) {
            self.should_exit = true;
            return;
        }

        if (std.mem.eql(u8, command, "provider")) {
            const first_arg = parts.next();
            if (first_arg == null) {
                if (std.mem.eql(u8, self.app_state.selected_provider_id, "openai")) {
                    try self.setNoticeFmt(
                        "Current provider: openai (auth:{s}). Use /provider [openai] [auto|api_key|codex]",
                        .{openAiAuthModeLabel(self.openai_auth_mode)},
                    );
                } else {
                    try self.setNoticeFmt("Current provider: {s}. Use /provider <id>", .{self.app_state.selected_provider_id});
                }
                return;
            }

            if (parseOpenAiAuthModeName(first_arg.?)) |mode_only| {
                if (!std.mem.eql(u8, self.app_state.selected_provider_id, "openai")) {
                    try self.setNotice("OpenAI auth mode only applies when provider is openai.");
                    return;
                }

                self.openai_auth_mode = mode_only;
                var codex_ready = true;
                if (mode_only == .codex) {
                    codex_ready = try self.ensureOpenAiCodexLoggedIn();
                }
                try self.app_state.saveToPath(self.allocator, self.paths.state_path);
                if (mode_only == .codex and !codex_ready) {
                    try self.setNotice("OpenAI auth mode set to codex, but login is still missing. Run `codex login` and retry.");
                } else {
                    try self.setNoticeFmt("OpenAI auth mode set to {s}", .{openAiAuthModeLabel(self.openai_auth_mode)});
                }
                return;
            }

            const provider_id = first_arg.?;
            const maybe_auth_mode_arg = parts.next();
            if (parts.next() != null) {
                try self.setNotice("Usage: /provider <id> [auto|api_key|codex]");
                return;
            }

            if (!std.mem.eql(u8, provider_id, "openai") and maybe_auth_mode_arg != null) {
                try self.setNotice("OpenAI auth mode options are only valid with provider 'openai'.");
                return;
            }

            var selected_openai_auth_mode = self.openai_auth_mode;
            if (maybe_auth_mode_arg) |token| {
                selected_openai_auth_mode = parseOpenAiAuthModeName(token) orelse {
                    try self.setNotice("Unknown OpenAI auth mode. Use: auto, api_key, codex");
                    return;
                };
            }

            try self.app_state.setSelectedProvider(self.allocator, provider_id);
            if (!self.catalog.hasModel(provider_id, self.app_state.selected_model_id)) {
                if (self.catalog.findProviderConst(provider_id)) |provider| {
                    if (provider.models.items.len > 0) {
                        try self.app_state.setSelectedModel(self.allocator, provider.models.items[0].id);
                    }
                }
            }

            if (std.mem.eql(u8, provider_id, "openai")) {
                self.openai_auth_mode = selected_openai_auth_mode;
                var codex_ready = true;
                if (self.openai_auth_mode == .codex) {
                    codex_ready = try self.ensureOpenAiCodexLoggedIn();
                }
                try self.app_state.saveToPath(self.allocator, self.paths.state_path);

                if (self.openai_auth_mode == .codex and !codex_ready) {
                    try self.setNotice("Provider set to openai (auth:codex), but login is missing. Run `codex login` and retry.");
                } else {
                    try self.setNoticeFmt("Provider set to openai (auth:{s})", .{openAiAuthModeLabel(self.openai_auth_mode)});
                }
                return;
            }

            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            try self.setNoticeFmt("Provider set to {s}", .{provider_id});
            return;
        }

        if (std.mem.eql(u8, command, "model")) {
            const model_id = parts.next();
            if (model_id == null) {
                const provider = self.catalog.findProviderConst(self.app_state.selected_provider_id);
                if (provider) |info| {
                    var line_writer: std.Io.Writer.Allocating = .init(self.allocator);
                    defer line_writer.deinit();
                    try line_writer.writer.print("Current model: {s}. Examples: ", .{self.app_state.selected_model_id});
                    const limit = @min(info.models.items.len, 4);
                    for (info.models.items[0..limit], 0..) |model, index| {
                        if (index > 0) try line_writer.writer.writeAll(", ");
                        try line_writer.writer.writeAll(model.id);
                    }
                    const notice = try line_writer.toOwnedSlice();
                    try self.setNoticeOwned(notice);
                } else {
                    try self.setNoticeFmt("Current model: {s}", .{self.app_state.selected_model_id});
                }
                return;
            }

            try self.app_state.setSelectedModel(self.allocator, model_id.?);
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);

            if (!self.catalog.hasModel(self.app_state.selected_provider_id, model_id.?)) {
                try self.setNoticeFmt("Model set to {s} (not found in cache for provider {s})", .{ model_id.?, self.app_state.selected_provider_id });
            } else {
                try self.setNoticeFmt("Model set to {s}", .{model_id.?});
            }
            return;
        }

        if (std.mem.eql(u8, command, "models")) {
            const action = parts.next();
            if (action != null and std.mem.eql(u8, action.?, "refresh")) {
                models.refreshToPath(self.allocator, self.paths.models_cache_path) catch |err| {
                    try self.setNoticeFmt("models refresh failed: {s}", .{@errorName(err)});
                    return;
                };

                const fresh_catalog = models.loadFromPath(self.allocator, self.paths.models_cache_path) catch |err| {
                    try self.setNoticeFmt("failed to reload models cache: {s}", .{@errorName(err)});
                    return;
                };

                self.catalog.deinit(self.allocator);
                self.catalog.* = fresh_catalog;

                try self.setNoticeFmt("models cache refreshed ({d} providers)", .{self.catalog.providers.items.len});
                return;
            }

            try self.setNoticeFmt("models cache has {d} providers. Use /model to inspect current provider.", .{self.catalog.providers.items.len});
            return;
        }

        if (std.mem.eql(u8, command, "files")) {
            const action = parts.next();
            if (action != null and std.mem.eql(u8, action.?, "refresh")) {
                self.file_index_attempted = true;
                self.refreshFileIndex() catch |err| {
                    try self.setNoticeFmt("file index refresh failed: {s}", .{@errorName(err)});
                    return;
                };
                self.file_index_loaded = true;
                try self.setNoticeFmt("file index refreshed ({d} files)", .{self.file_index.items.len});
                return;
            }

            if (!self.file_index_attempted) {
                try self.setNotice("file index not loaded yet (lazy). Type @ to load, or use /files refresh.");
                return;
            }
            if (!self.file_index_loaded) {
                try self.setNotice("file index unavailable (last load failed). Use /files refresh to retry.");
                return;
            }
            try self.setNoticeFmt("file index has {d} files. Use /files refresh after file changes.", .{self.file_index.items.len});
            return;
        }

        if (std.mem.eql(u8, command, "skills")) {
            const action = parts.next();
            if (action != null and std.mem.eql(u8, action.?, "refresh")) {
                try self.refreshSkills();
                try self.setNoticeFmt("skills cache refreshed ({d} skills)", .{self.skills.items.len});
                return;
            }

            try self.ensureSkillsLoaded();
            if (self.skills.items.len == 0) {
                try self.setNotice("No skills discovered. Use .opencode/skills, .agents/skills, .claude/skills, .codex/skills, or global ~/.config/zolt/skills.");
                return;
            }

            if (action) |skill_name| {
                const skill = self.findSkillByName(skill_name) orelse {
                    try self.setNoticeFmt("Skill not found: {s}", .{skill_name});
                    return;
                };

                const cwd = std.process.getCwdAlloc(self.allocator) catch null;
                defer if (cwd) |path| self.allocator.free(path);
                const repo_root = findGitTopLevelAlloc(self.allocator) catch null;
                defer if (repo_root) |path| self.allocator.free(path);
                const display_path = try formatInjectedPathForSummaryAlloc(self.allocator, skill.path, cwd, repo_root);
                defer self.allocator.free(display_path);

                try self.setNoticeFmt(
                    "skill {s} ({s}) path:{s} - {s}",
                    .{ skill.name, self.skillScopeLabel(skill.scope), display_path, skill.description },
                );
                return;
            }

            var line_writer: std.Io.Writer.Allocating = .init(self.allocator);
            defer line_writer.deinit();
            try line_writer.writer.print("skills ({d}): ", .{self.skills.items.len});
            const shown = @min(self.skills.items.len, @as(usize, 5));
            for (self.skills.items[0..shown], 0..) |skill, idx| {
                if (idx > 0) try line_writer.writer.writeAll(", ");
                try line_writer.writer.writeAll(skill.name);
            }
            if (self.skills.items.len > shown) {
                try line_writer.writer.print(" (+{d} more)", .{self.skills.items.len - shown});
            }
            try line_writer.writer.writeAll(". Use /skills <name> to inspect or /skills refresh.");
            try self.setNoticeOwned(try line_writer.toOwnedSlice());
            return;
        }

        if (std.mem.eql(u8, command, "compact")) {
            const action = parts.next();
            if (action == null) {
                const provider_id = self.app_state.selected_provider_id;
                const model_id = self.app_state.selected_model_id;
                var maybe_auth = try self.resolveProviderAuth(provider_id);
                defer if (maybe_auth) |*auth| auth.deinit(self.allocator);

                const compacted = try self.compactCurrentConversation(
                    provider_id,
                    model_id,
                    if (maybe_auth) |*auth| auth else null,
                    .manual,
                    null,
                );
                if (!compacted) {
                    try self.setNotice("Nothing to compact yet (need more history).");
                    return;
                }
                try self.app_state.saveToPath(self.allocator, self.paths.state_path);
                return;
            }

            if (std.mem.eql(u8, action.?, "auto")) {
                const mode = parts.next();
                if (mode == null) {
                    try self.setNoticeFmt("Auto compact: {s} (trigger <= {d}% left)", .{
                        if (self.auto_compact_enabled) "on" else "off",
                        self.auto_compact_percent_left,
                    });
                    return;
                }
                if (std.mem.eql(u8, mode.?, "on")) {
                    self.auto_compact_enabled = true;
                    try self.setNoticeFmt("Auto compact enabled (trigger <= {d}% left)", .{self.auto_compact_percent_left});
                    return;
                }
                if (std.mem.eql(u8, mode.?, "off")) {
                    self.auto_compact_enabled = false;
                    try self.setNotice("Auto compact disabled");
                    return;
                }

                try self.setNotice("Usage: /compact [auto [on|off]]");
                return;
            }

            try self.setNotice("Usage: /compact [auto [on|off]]");
            return;
        }

        if (std.mem.eql(u8, command, "paste-image")) {
            try self.pasteClipboardImageIntoInput();
            return;
        }

        if (std.mem.eql(u8, command, "new")) {
            const title = blk: {
                const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse break :blk "New conversation";
                const remainder = std.mem.trim(u8, line[first_space + 1 ..], " ");
                if (remainder.len == 0) break :blk "New conversation";
                break :blk remainder;
            };
            _ = try self.app_state.createConversation(self.allocator, title);
            self.scroll_lines = 0;
            self.ensureCurrentConversationVisibleInStrip();
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            try self.setNoticeFmt("Created conversation: {s}", .{self.app_state.currentConversationConst().id});
            return;
        }

        if (std.mem.eql(u8, command, "sessions") or std.mem.eql(u8, command, "switch")) {
            const conversation_id = parts.next() orelse {
                try self.openConversationSwitchPicker();
                return;
            };

            if (!(try self.app_state.switchConversation(self.allocator, conversation_id))) {
                try self.setNoticeFmt("Conversation not found: {s}", .{conversation_id});
                return;
            }

            self.scroll_lines = 0;
            self.ensureCurrentConversationVisibleInStrip();
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            try self.setNoticeFmt("Switched to conversation: {s}", .{conversation_id});
            return;
        }

        if (std.mem.eql(u8, command, "title")) {
            const title_offset = std.mem.indexOf(u8, line, " ") orelse {
                try self.setNotice("Usage: /title <new title>");
                return;
            };
            const title = std.mem.trim(u8, line[title_offset + 1 ..], " ");
            if (title.len == 0) {
                try self.setNotice("Usage: /title <new title>");
                return;
            }

            try self.app_state.setConversationTitle(self.allocator, title);
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);
            try self.setNoticeFmt("Conversation renamed to: {s}", .{title});
            return;
        }

        if (std.mem.eql(u8, command, "theme")) {
            const theme_name = parts.next();
            if (theme_name == null) {
                try self.setNoticeFmt("Current theme: {s}", .{@tagName(self.theme)});
                return;
            }

            if (std.mem.eql(u8, theme_name.?, "codex")) self.theme = .codex else if (std.mem.eql(u8, theme_name.?, "plain")) self.theme = .plain else if (std.mem.eql(u8, theme_name.?, "forest")) self.theme = .forest else {
                try self.setNotice("Unknown theme. Use: codex, plain, forest");
                return;
            }

            try self.setNoticeFmt("Theme set to {s}", .{theme_name.?});
            return;
        }

        if (std.mem.eql(u8, command, "ui")) {
            const mode_name = parts.next() orelse {
                try self.setNoticeFmt("UI mode: {s}", .{if (self.compact_mode) "compact" else "comfy"});
                return;
            };

            if (std.mem.eql(u8, mode_name, "compact")) {
                self.compact_mode = true;
                try self.setNotice("UI mode set to compact");
                return;
            }
            if (std.mem.eql(u8, mode_name, "comfy")) {
                self.compact_mode = false;
                try self.setNotice("UI mode set to comfy");
                return;
            }

            try self.setNotice("Usage: /ui [compact|comfy]");
            return;
        }

        try self.setNoticeFmt("Unknown command: /{s}", .{command});
    }

    pub fn resolveApiKey(self: *App, provider_id: []const u8) !?[]u8 {
        if (self.catalog.findProviderConst(provider_id)) |provider| {
            if (provider.env_vars.items.len > 0) {
                for (provider.env_vars.items) |env_var| {
                    const value = std.process.getEnvVarOwned(self.allocator, env_var) catch |err| switch (err) {
                        error.EnvironmentVariableNotFound => null,
                        else => return err,
                    };
                    if (value) |key| return key;
                }
            }
        }

        const fallback = fallbackEnvVars(provider_id);
        for (fallback) |env_var| {
            const value = std.process.getEnvVarOwned(self.allocator, env_var) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => null,
                else => return err,
            };
            if (value) |key| return key;
        }

        return null;
    }

    fn resolveProviderAuth(self: *App, provider_id: []const u8) !?ResolvedProviderAuth {
        if (std.mem.eql(u8, provider_id, "openai")) {
            return try self.resolveOpenAiProviderAuth();
        }

        if (try self.resolveApiKey(provider_id)) |api_key| {
            return .{
                .bearer_token = api_key,
                .source = .api_key_env,
            };
        }

        return null;
    }

    fn resolveOpenAiProviderAuth(self: *App) !?ResolvedProviderAuth {
        const auth_mode = try self.resolveOpenAiAuthMode();
        switch (auth_mode) {
            .codex => {
                if (try self.resolveOpenAiCodexSubscriptionAuth()) |auth| return auth;
                if (try self.resolveOpenAiOpenCodeSubscriptionAuth()) |auth| return auth;
                if (try self.resolveApiKey("openai")) |api_key| {
                    return .{
                        .bearer_token = api_key,
                        .source = .api_key_env,
                    };
                }
                return null;
            },
            .api_key => {
                if (try self.resolveApiKey("openai")) |api_key| {
                    return .{
                        .bearer_token = api_key,
                        .source = .api_key_env,
                    };
                }
                return null;
            },
            .auto => {
                if (try self.resolveApiKey("openai")) |api_key| {
                    return .{
                        .bearer_token = api_key,
                        .source = .api_key_env,
                    };
                }
                if (try self.resolveOpenAiCodexSubscriptionAuth()) |auth| return auth;
                return try self.resolveOpenAiOpenCodeSubscriptionAuth();
            },
        }
    }

    fn resolveOpenAiAuthMode(self: *App) !OpenAiAuthMode {
        if (self.openai_auth_mode != .auto) return self.openai_auth_mode;

        const mode_raw = std.process.getEnvVarOwned(self.allocator, "ZOLT_OPENAI_AUTH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        if (mode_raw) |text| {
            defer self.allocator.free(text);
            if (parseOpenAiAuthModeName(text)) |mode| return mode;
        }
        return .auto;
    }

    fn resolveOpenAiCodexSubscriptionAuth(self: *App) !?ResolvedProviderAuth {
        const auth_path = try resolveCodexAuthPath(self.allocator) orelse return null;
        defer self.allocator.free(auth_path);

        var file = openFileForPath(auth_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const payload = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| switch (err) {
            error.FileTooBig => return null,
            else => return err,
        };
        defer self.allocator.free(payload);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return null;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const tokens_value = root.get("tokens") orelse return null;
        const tokens = switch (tokens_value) {
            .object => |object| object,
            else => return null,
        };

        const access_token_raw = jsonObjectFieldString(tokens, "access_token") orelse return null;
        const access_token = std.mem.trim(u8, access_token_raw, " \t\r\n");
        if (access_token.len == 0) return null;

        const bearer_token = try self.allocator.dupe(u8, access_token);
        errdefer self.allocator.free(bearer_token);

        var account_id: ?[]u8 = null;
        errdefer if (account_id) |account| self.allocator.free(account);

        if (jsonObjectFieldString(tokens, "account_id")) |account_raw| {
            const trimmed = std.mem.trim(u8, account_raw, " \t\r\n");
            if (trimmed.len > 0) {
                account_id = try self.allocator.dupe(u8, trimmed);
            }
        }

        if (account_id == null) {
            if (jsonObjectFieldString(tokens, "id_token")) |id_token| {
                account_id = try extractChatgptAccountIdFromJwtAlloc(self.allocator, id_token);
            }
        }

        if (account_id == null) {
            if (jsonObjectFieldString(tokens, "access_token")) |jwt| {
                account_id = try extractChatgptAccountIdFromJwtAlloc(self.allocator, jwt);
            }
        }

        return .{
            .bearer_token = bearer_token,
            .chatgpt_account_id = account_id,
            .prefer_responses_api = true,
            .base_url_override = OPENAI_CODEX_BASE_URL,
            .source = .codex_subscription,
        };
    }

    fn resolveOpenAiOpenCodeSubscriptionAuth(self: *App) !?ResolvedProviderAuth {
        const auth_path = try resolveOpenCodeAuthPath(self.allocator) orelse return null;
        defer self.allocator.free(auth_path);

        var file = openFileForPath(auth_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const payload = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| switch (err) {
            error.FileTooBig => return null,
            else => return err,
        };
        defer self.allocator.free(payload);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return null;
        defer parsed.deinit();

        const root = switch (parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const openai_value = root.get("openai") orelse return null;
        const openai_auth = switch (openai_value) {
            .object => |object| object,
            else => return null,
        };

        const auth_type = jsonObjectFieldString(openai_auth, "type") orelse return null;
        if (!std.mem.eql(u8, auth_type, "oauth")) return null;

        const access_token_raw = jsonObjectFieldString(openai_auth, "access") orelse return null;
        const access_token = std.mem.trim(u8, access_token_raw, " \t\r\n");
        if (access_token.len == 0) return null;

        const bearer_token = try self.allocator.dupe(u8, access_token);
        errdefer self.allocator.free(bearer_token);

        var account_id: ?[]u8 = null;
        errdefer if (account_id) |account| self.allocator.free(account);

        if (jsonObjectFieldString(openai_auth, "accountId")) |account_raw| {
            const trimmed = std.mem.trim(u8, account_raw, " \t\r\n");
            if (trimmed.len > 0) account_id = try self.allocator.dupe(u8, trimmed);
        }
        if (account_id == null) {
            if (jsonObjectFieldString(openai_auth, "account_id")) |account_raw| {
                const trimmed = std.mem.trim(u8, account_raw, " \t\r\n");
                if (trimmed.len > 0) account_id = try self.allocator.dupe(u8, trimmed);
            }
        }
        if (account_id == null) {
            account_id = try extractChatgptAccountIdFromJwtAlloc(self.allocator, access_token);
        }

        return .{
            .bearer_token = bearer_token,
            .chatgpt_account_id = account_id,
            .prefer_responses_api = true,
            .base_url_override = OPENAI_CODEX_BASE_URL,
            .source = .codex_subscription,
        };
    }

    fn hasOpenAiSubscriptionAuth(self: *App) !bool {
        if (try self.resolveOpenAiCodexSubscriptionAuth()) |auth| {
            var owned = auth;
            owned.deinit(self.allocator);
            return true;
        }
        if (try self.resolveOpenAiOpenCodeSubscriptionAuth()) |auth| {
            var owned = auth;
            owned.deinit(self.allocator);
            return true;
        }
        return false;
    }

    fn ensureOpenAiCodexLoggedIn(self: *App) !bool {
        if (try self.hasOpenAiSubscriptionAuth()) return true;
        if (self.headless) return false;

        try self.setNotice("No Codex/OpenCode OAuth token found. Running `codex login`...");
        try self.render();

        const login_ok = try self.runCodexLoginCommand();
        if (!login_ok) {
            try self.setNotice("Codex login failed. Run `codex login` manually and retry.");
            return false;
        }

        if (try self.hasOpenAiSubscriptionAuth()) return true;
        try self.setNotice("Codex login completed but no auth token was found. Run `codex login` manually.");
        return false;
    }

    fn runCodexLoginCommand(self: *App) !bool {
        const stdin_handle = std.fs.File.stdin().handle;
        const raw_termios = std.posix.tcgetattr(stdin_handle) catch null;
        if (raw_termios) |raw| {
            var cooked = raw;
            cooked.iflag.ICRNL = true;
            cooked.iflag.IXON = true;
            cooked.lflag.ECHO = true;
            cooked.lflag.ICANON = true;
            cooked.lflag.ISIG = true;
            cooked.lflag.IEXTEN = true;
            cooked.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            cooked.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            std.posix.tcsetattr(stdin_handle, .NOW, cooked) catch {};
            defer std.posix.tcsetattr(stdin_handle, .NOW, raw) catch {};
        }

        _ = std.posix.write(std.fs.File.stdout().handle, "\nLaunching codex login...\n") catch {};

        var child = std.process.Child.init(&.{ "codex", "login" }, self.allocator);
        child.cwd = ".";
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch |err| switch (err) {
            error.FileNotFound => {
                try self.setNotice("`codex` not found in PATH. Install codex CLI or run with OPENAI_API_KEY.");
                return false;
            },
            else => return err,
        };
        child.waitForSpawn() catch |err| {
            try self.setNoticeFmt("Failed to start codex login: {s}", .{@errorName(err)});
            return false;
        };

        const term = child.wait() catch |err| {
            try self.setNoticeFmt("codex login wait failed: {s}", .{@errorName(err)});
            return false;
        };

        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    fn setNotice(self: *App, text: []const u8) !void {
        const replacement = try self.allocator.dupe(u8, text);
        self.allocator.free(self.notice);
        self.notice = replacement;
    }

    fn setNoticeOwned(self: *App, owned_text: []u8) !void {
        self.allocator.free(self.notice);
        self.notice = owned_text;
    }

    fn setNoticeFmt(self: *App, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        try self.setNoticeOwned(text);
    }

    fn clearLastRunError(self: *App) void {
        if (self.last_run_error) |*err_info| err_info.deinit(self.allocator);
        self.last_run_error = null;
    }

    fn setLastRunError(
        self: *App,
        code: []const u8,
        message: []const u8,
        retryable: bool,
        source: []const u8,
    ) !void {
        self.clearLastRunError();
        self.last_run_error = .{
            .code = try self.allocator.dupe(u8, code),
            .message = try self.allocator.dupe(u8, message),
            .retryable = retryable,
            .source = try self.allocator.dupe(u8, source),
        };
    }

    fn clearLastSuccessfulTool(self: *App) void {
        if (self.last_successful_tool_call) |value| self.allocator.free(value);
        self.last_successful_tool_call = null;
        if (self.last_successful_tool_result_summary) |value| self.allocator.free(value);
        self.last_successful_tool_result_summary = null;
    }

    fn recordSuccessfulTool(self: *App, tool_call: []const u8, tool_result: []const u8) !void {
        self.clearLastSuccessfulTool();
        self.last_successful_tool_call = try self.allocator.dupe(u8, tool_call);
        self.last_successful_tool_result_summary = try summarizeToolResultAlloc(self.allocator, tool_result);
    }

    fn buildToolFallbackSummaryAlloc(self: *App, reason: []const u8) ![]u8 {
        return buildToolFallbackSummaryFromLastToolAlloc(
            self.allocator,
            self.last_successful_tool_call,
            self.last_successful_tool_result_summary,
            reason,
        );
    }

    fn ensureLastAssistantUserFacing(self: *App) !void {
        const conversation = self.app_state.currentConversationConst();
        if (conversation.messages.items.len == 0) return;
        const last = conversation.messages.items[conversation.messages.items.len - 1];
        if (last.role != .assistant) return;

        const sanitized = try sanitizeFinalUserFacingResponseAlloc(
            self.allocator,
            last.content,
            self.last_successful_tool_call,
            self.last_successful_tool_result_summary,
            "finalize",
        );
        defer self.allocator.free(sanitized);

        if (!std.mem.eql(u8, sanitized, last.content)) {
            try self.setLastAssistantMessage(sanitized);
        }
    }

    fn latestAssistantResponseAlloc(self: *App) ![]u8 {
        const conversation = self.app_state.currentConversationConst();

        // Prefer the latest non-tool assistant text for headless `zolt run` output.
        var index = conversation.messages.items.len;
        while (index > 0) {
            index -= 1;
            const message = conversation.messages.items[index];
            if (message.role != .assistant) continue;
            const trimmed = std.mem.trim(u8, message.content, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (parseAssistantToolCall(trimmed) != null) continue;
            return self.allocator.dupe(u8, message.content);
        }

        // No valid assistant text: synthesize a user-facing fallback from latest tool result.
        return self.buildToolFallbackSummaryAlloc("no_user_facing_response");
    }

    fn render(self: *App) !void {
        if (self.headless) return;

        var screen_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer screen_writer.deinit();

        const conversation = self.app_state.currentConversationConst();
        const palette = paletteForTheme(self.theme);

        const metrics = self.terminalMetrics();
        const width = metrics.width;
        const lines = metrics.lines;
        const content_width = if (width > 4) width - 4 else 56;
        const top_lines: usize = if (self.compact_mode) 2 else 4;
        const picker_lines = self.pickerLineCount(lines);
        const bottom_lines: usize = 3 + picker_lines;
        const viewport_height = @max(@as(usize, 4), lines - top_lines - bottom_lines);

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();
        const now_ms = std.time.milliTimestamp();
        const stream_notice = if (self.is_streaming)
            try buildStreamingNotice(self.allocator, streamTaskTitle(self.stream_task), self.stream_started_ms, now_ms)
        else
            null;
        defer if (stream_notice) |text| self.allocator.free(text);
        const active_notice = stream_notice orelse self.notice;
        const last_index = if (conversation.messages.items.len == 0) @as(usize, 0) else conversation.messages.items.len - 1;
        for (conversation.messages.items, 0..) |message, index| {
            const loading_placeholder = if (self.is_streaming and
                index == last_index and
                message.role == .assistant and
                message.content.len == 0)
                try buildWorkingPlaceholder(self.allocator, streamTaskTitle(self.stream_task), self.stream_started_ms, now_ms)
            else
                null;
            defer if (loading_placeholder) |text| self.allocator.free(text);

            try appendMessageBlock(
                self.allocator,
                &body_writer.writer,
                message,
                content_width,
                palette,
                self.compact_mode,
                loading_placeholder,
            );
        }
        const body = try body_writer.toOwnedSlice();
        defer self.allocator.free(body);

        var body_lines: std.ArrayList([]const u8) = .empty;
        defer body_lines.deinit(self.allocator);
        var split_lines = std.mem.splitScalar(u8, body, '\n');
        while (split_lines.next()) |line| {
            try body_lines.append(self.allocator, line);
        }
        if (body_lines.items.len > 0 and body_lines.items[body_lines.items.len - 1].len == 0) {
            _ = body_lines.orderedRemove(body_lines.items.len - 1);
        }

        const total_body_lines = body_lines.items.len;
        const max_scroll = if (total_body_lines > viewport_height) total_body_lines - viewport_height else 0;
        if (self.scroll_lines > max_scroll) self.scroll_lines = max_scroll;

        const start_line = if (total_body_lines > viewport_height) total_body_lines - viewport_height - self.scroll_lines else 0;
        const end_line = @min(start_line + viewport_height, total_body_lines);

        try screen_writer.writer.writeAll("\x1b[2J\x1b[H");

        const mode_label = if (self.mode == .insert) "insert" else "normal";
        const stream_label = if (self.is_streaming) "streaming" else "idle";
        const short_conv_id = if (conversation.id.len > 10) conversation.id[0..10] else conversation.id;

        if (self.compact_mode) {
            const compact = try std.fmt.allocPrint(
                self.allocator,
                "Zolt  {s}/{s}  mode:{s}  conv:{s}  {s}",
                .{ self.app_state.selected_provider_id, self.app_state.selected_model_id, mode_label, short_conv_id, stream_label },
            );
            defer self.allocator.free(compact);
            const compact_line = try truncateLineAlloc(self.allocator, compact, width);
            defer self.allocator.free(compact_line);
            try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.header, compact_line, palette.reset });
        } else {
            const title = try std.fmt.allocPrint(
                self.allocator,
                "Zolt  mode:{s}  conv:{s}",
                .{ mode_label, conversation.id },
            );
            defer self.allocator.free(title);
            const title_line = try truncateLineAlloc(self.allocator, title, width);
            defer self.allocator.free(title_line);
            try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.header, title_line, palette.reset });

            const model_line = try std.fmt.allocPrint(
                self.allocator,
                "model: {s}/{s}  theme:{s}  ui:{s}  status:{s}",
                .{ self.app_state.selected_provider_id, self.app_state.selected_model_id, @tagName(self.theme), if (self.compact_mode) "compact" else "comfy", stream_label },
            );
            defer self.allocator.free(model_line);
            const model_trimmed = try truncateLineAlloc(self.allocator, model_line, width);
            defer self.allocator.free(model_trimmed);
            try screen_writer.writer.writeAll(model_trimmed);
            try screen_writer.writer.writeByte('\n');

            const note_text = try std.fmt.allocPrint(self.allocator, "note: {s}", .{active_notice});
            defer self.allocator.free(note_text);
            const note_line = try truncateLineAlloc(self.allocator, note_text, width);
            defer self.allocator.free(note_line);
            try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.dim, note_line, palette.reset });
        }

        try writeRule(&screen_writer.writer, width, palette, self.compact_mode);

        var rendered_lines: usize = 0;
        for (body_lines.items[start_line..end_line]) |line| {
            try screen_writer.writer.writeAll(line);
            try screen_writer.writer.writeByte('\n');
            rendered_lines += 1;
        }
        while (rendered_lines < viewport_height) : (rendered_lines += 1) {
            try screen_writer.writer.writeByte('\n');
        }

        try writeRule(&screen_writer.writer, width, palette, self.compact_mode);

        const key_hint = if (self.is_streaming)
            "esc esc stop pgup/pgdn"
        else if (self.model_picker_open)
            "ctrl-n/p or up/down, enter/tab select, esc close"
        else if (self.command_picker_open)
            if (self.command_picker_kind == .quick_actions)
                "ctrl-n/p or up/down, enter/tab run, esc close"
            else if (self.command_picker_kind == .conversation_switch)
                "ctrl-n/p or up/down, enter/tab switch, esc close"
            else
                "ctrl-n/p or up/down, enter/tab insert, esc close"
        else if (self.file_picker_open)
            "ctrl-n/p or up/down, enter/tab insert, esc close"
        else if (self.mode == .insert)
            "enter esc / ctrl-p ctrl-v pgup/pgdn"
        else
            "i j/k pgup/pgdn / ctrl-p q";
        const context_summary = try self.contextUsageSummary(conversation);
        defer if (context_summary) |summary| self.allocator.free(summary);
        const status_text = if (context_summary) |summary|
            try std.fmt.allocPrint(
                self.allocator,
                "{s} | {s} | keys:{s} | scroll:{d}/{d}",
                .{ active_notice, summary, key_hint, self.scroll_lines, max_scroll },
            )
        else
            try std.fmt.allocPrint(
                self.allocator,
                "{s} | keys:{s} | scroll:{d}/{d}",
                .{ active_notice, key_hint, self.scroll_lines, max_scroll },
            );
        defer self.allocator.free(status_text);
        const status_line = try truncateLineAlloc(self.allocator, status_text, width);
        defer self.allocator.free(status_line);
        try screen_writer.writer.print("{s}{s}{s}\n", .{ palette.dim, status_line, palette.reset });

        if (self.model_picker_open) {
            try self.renderModelPicker(&screen_writer.writer, width, lines, palette);
        } else if (self.command_picker_open) {
            try self.renderCommandPicker(&screen_writer.writer, width, lines, palette);
        } else if (self.file_picker_open) {
            try self.renderFilePicker(&screen_writer.writer, width, lines, palette);
        }

        const before_cursor = self.input_buffer.items[0..self.input_cursor];
        const after_cursor = self.input_buffer.items[self.input_cursor..];
        const input_view = try buildInputView(self.allocator, before_cursor, after_cursor, if (width > 10) width - 10 else 22);
        defer self.allocator.free(input_view.text);
        try screen_writer.writer.print("{s}[{s}]>{s} {s}", .{ palette.accent, if (self.mode == .insert) "INS" else "NOR", palette.reset, input_view.text });

        const cursor = computeInputCursorPlacement(
            width,
            lines,
            self.compact_mode,
            viewport_height,
            picker_lines,
            input_view.cursor_col,
        );
        try screen_writer.writer.print("\x1b[{d};{d}H", .{ cursor.row, cursor.col });

        const screen = try screen_writer.toOwnedSlice();
        defer self.allocator.free(screen);

        var stdout_buffer: [16 * 1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        defer stdout_writer.interface.flush() catch {};

        try stdout_writer.interface.writeAll(screen);
    }

    fn buildConversationStrip(self: *App, width: usize) ![]u8 {
        var strip_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer strip_writer.deinit();

        const conversations = self.app_state.conversations.items;
        var ordered_indices = try collectConversationSwitchMatchOrder(
            self.allocator,
            conversations,
            self.app_state.current_index,
            "",
            false,
        );
        defer ordered_indices.deinit(self.allocator);

        const total = ordered_indices.items.len;
        if (total == 0) return self.allocator.dupe(u8, "convs: none");

        const window_size: usize = 6;
        const max_start = if (total > window_size) total - window_size else 0;
        const start_index = @min(self.conv_strip_start, max_start);
        const max_items: usize = @min(total - start_index, window_size);
        const end_index = @min(start_index + max_items, total);

        var current_rank: usize = 0;
        for (ordered_indices.items, 0..) |conversation_index, rank| {
            if (conversation_index == self.app_state.current_index) {
                current_rank = rank;
                break;
            }
        }

        try strip_writer.writer.print("convs({d}/{d}):", .{ current_rank + 1, total });
        if (start_index > 0) try strip_writer.writer.writeAll(" ..");

        for (ordered_indices.items[start_index..end_index], start_index..) |conversation_index, index| {
            const conv = conversations[conversation_index];
            const marker = if (conversation_index == self.app_state.current_index) "*" else "";
            const short_id = conv.id[0..@min(conv.id.len, 6)];
            const title_limit: usize = 14;

            try strip_writer.writer.print(" {s}{s}:", .{ marker, short_id });
            if (conv.title.len <= title_limit) {
                try strip_writer.writer.writeAll(conv.title);
            } else {
                try strip_writer.writer.writeAll(conv.title[0 .. title_limit - 3]);
                try strip_writer.writer.writeAll("...");
            }

            if (index + 1 < end_index) try strip_writer.writer.writeAll(" |");
        }

        if (end_index < total) try strip_writer.writer.writeAll(" ..");

        const raw = try strip_writer.toOwnedSlice();
        defer self.allocator.free(raw);
        return truncateLineAlloc(self.allocator, raw, width);
    }

    fn shiftConversationStrip(self: *App, delta: i32) void {
        const total = countVisibleSessionConversations(
            self.app_state.conversations.items,
            self.app_state.current_index,
            false,
        );
        const window_size: usize = 6;
        const max_start = if (total > window_size) total - window_size else 0;

        if (delta < 0) {
            if (self.conv_strip_start > 0) self.conv_strip_start -= 1;
            return;
        }
        if (delta > 0) {
            if (self.conv_strip_start < max_start) self.conv_strip_start += 1;
        }
    }

    fn ensureCurrentConversationVisibleInStrip(self: *App) void {
        const total = countVisibleSessionConversations(
            self.app_state.conversations.items,
            self.app_state.current_index,
            false,
        );
        if (total == 0) {
            self.conv_strip_start = 0;
            return;
        }

        const window_size: usize = 6;
        const max_start = if (total > window_size) total - window_size else 0;
        const conversations = self.app_state.conversations.items;
        var current_rank: usize = 0;
        for (conversations, 0..) |_, index| {
            if (!shouldIncludeConversationInSessionOrder(
                conversations,
                index,
                self.app_state.current_index,
                false,
            )) continue;
            if (index == self.app_state.current_index) continue;
            if (conversationSortComesBefore(conversations, index, self.app_state.current_index)) {
                current_rank += 1;
            }
        }

        if (current_rank < self.conv_strip_start) {
            self.conv_strip_start = current_rank;
        } else if (current_rank >= self.conv_strip_start + window_size) {
            self.conv_strip_start = current_rank - window_size + 1;
        }

        if (self.conv_strip_start > max_start) self.conv_strip_start = max_start;
    }

    fn terminalMetrics(_: *App) TerminalMetrics {
        if (builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd) {
            var winsize: std.posix.winsize = .{
                .row = 0,
                .col = 0,
                .xpixel = 0,
                .ypixel = 0,
            };
            const rc = std.posix.system.ioctl(std.fs.File.stdout().handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
            if (std.posix.errno(rc) == .SUCCESS and winsize.col > 0 and winsize.row > 0) {
                return .{
                    .width = std.math.clamp(@as(usize, winsize.col), 64, 220),
                    .lines = std.math.clamp(@as(usize, winsize.row), 20, 120),
                };
            }
        }

        const env_width = std.process.parseEnvVarInt("COLUMNS", usize, 10) catch 120;
        const env_lines = std.process.parseEnvVarInt("LINES", usize, 10) catch 40;
        return .{
            .width = std.math.clamp(env_width, 64, 220),
            .lines = std.math.clamp(env_lines, 20, 120),
        };
    }

    fn parseModelPickerQuery(input: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, input, "/model")) return null;
        if (input.len == 6) return "";
        if (input.len > 6 and input[6] == ' ') return std.mem.trimLeft(u8, input[7..], " ");
        return null;
    }

    fn syncPickersFromInput(self: *App) void {
        self.syncModelPickerFromInput();
        if (self.model_picker_open) {
            self.command_picker_open = false;
            self.command_picker_kind = .slash_commands;
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            self.file_picker_open = false;
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        }

        self.syncCommandPickerFromInput();
        if (self.command_picker_open) {
            self.file_picker_open = false;
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        }

        self.syncFilePickerFromInput();
    }

    fn syncModelPickerFromInput(self: *App) void {
        const query = parseModelPickerQuery(self.input_buffer.items);
        if (query == null) {
            self.model_picker_open = false;
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
            return;
        }

        if (!self.model_picker_open) {
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
        }
        self.model_picker_open = true;

        const total = self.modelPickerMatchCount(query.?);
        if (total == 0) {
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
            return;
        }
        if (self.model_picker_index >= total) self.model_picker_index = total - 1;
    }

    fn commandPickerQueryForKind(self: *App, kind: CommandPickerKind) ?[]const u8 {
        return switch (kind) {
            .slash_commands => parseSlashCommandPickerQuery(self.input_buffer.items, self.input_cursor),
            .quick_actions => parseQuickActionPickerQuery(self.input_buffer.items, self.input_cursor),
            .conversation_switch => parseConversationSwitchPickerQuery(self.input_buffer.items, self.input_cursor),
            .provider_options => parseProviderPickerQuery(self.input_buffer.items, self.input_cursor),
        };
    }

    fn syncCommandPickerFromInput(self: *App) void {
        const maybe_kind_query: ?struct { kind: CommandPickerKind, query: []const u8 } = blk: {
            if (parseConversationSwitchPickerQuery(self.input_buffer.items, self.input_cursor)) |query| {
                break :blk .{ .kind = .conversation_switch, .query = query };
            }
            if (parseProviderPickerQuery(self.input_buffer.items, self.input_cursor)) |query| {
                break :blk .{ .kind = .provider_options, .query = query };
            }
            if (parseQuickActionPickerQuery(self.input_buffer.items, self.input_cursor)) |query| {
                break :blk .{ .kind = .quick_actions, .query = query };
            }
            if (parseSlashCommandPickerQuery(self.input_buffer.items, self.input_cursor)) |query| {
                break :blk .{ .kind = .slash_commands, .query = query };
            }
            break :blk null;
        };

        const kind_query = maybe_kind_query orelse {
            self.command_picker_open = false;
            self.command_picker_kind = .slash_commands;
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            return;
        };

        if (!self.command_picker_open or self.command_picker_kind != kind_query.kind) {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
        }
        if (!self.command_picker_open) {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
        }
        self.command_picker_open = true;
        self.command_picker_kind = kind_query.kind;

        const total = self.commandPickerMatchCount(kind_query.query);
        if (total == 0) {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            return;
        }
        if (self.command_picker_index >= total) self.command_picker_index = total - 1;
    }

    fn syncFilePickerFromInput(self: *App) void {
        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse {
            self.file_picker_open = false;
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        };

        self.ensureFileIndexLoaded();
        if (!self.file_picker_open) {
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
        }
        self.file_picker_open = true;

        const total = self.filePickerMatchCount(query);
        if (total == 0) {
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        }
        if (self.file_picker_index >= total) self.file_picker_index = total - 1;
    }

    fn modelPickerMatchCount(self: *App, query: []const u8) usize {
        const provider = self.catalog.findProviderConst(self.app_state.selected_provider_id) orelse return 0;
        var count: usize = 0;
        for (provider.models.items) |model| {
            if (modelMatchesQuery(model, query)) count += 1;
        }
        return count;
    }

    fn selectedModelContextWindow(self: *App) ?i64 {
        const provider = self.catalog.findProviderConst(self.app_state.selected_provider_id) orelse return null;
        for (provider.models.items) |model| {
            if (std.mem.eql(u8, model.id, self.app_state.selected_model_id)) {
                return model.context_window;
            }
        }
        return null;
    }

    fn contextUsageSummary(self: *App, conversation: *const Conversation) !?[]u8 {
        const usage = conversation.last_token_usage;
        const window = conversation.model_context_window orelse self.selectedModelContextWindow();
        if (usage.isZero() and window == null) return null;

        const used = usage.tokensInContextWindow();
        const used_text = try formatTokenCount(self.allocator, used);
        defer self.allocator.free(used_text);

        if (window) |context_window| {
            const full_text = try formatTokenCount(self.allocator, context_window);
            defer self.allocator.free(full_text);
            const left_percent = usage.percentOfContextWindowRemaining(context_window);
            return @as(?[]u8, try std.fmt.allocPrint(self.allocator, "ctx:{s}/{s} {d}% left", .{ used_text, full_text, left_percent }));
        }

        return @as(?[]u8, try std.fmt.allocPrint(self.allocator, "ctx:{s} used", .{used_text}));
    }

    fn modelPickerNthMatch(self: *App, query: []const u8, target_index: usize) ?*const models.ModelInfo {
        const provider = self.catalog.findProviderConst(self.app_state.selected_provider_id) orelse return null;
        var seen: usize = 0;
        for (provider.models.items) |*model| {
            if (!modelMatchesQuery(model.*, query)) continue;
            if (seen == target_index) return model;
            seen += 1;
        }
        return null;
    }

    fn moveModelPickerSelection(self: *App, delta: i32) void {
        const query = parseModelPickerQuery(self.input_buffer.items) orelse return;
        const total = self.modelPickerMatchCount(query);
        if (total == 0) {
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
            return;
        }

        if (delta < 0) {
            if (self.model_picker_index > 0) self.model_picker_index -= 1;
        } else if (delta > 0) {
            if (self.model_picker_index + 1 < total) self.model_picker_index += 1;
        }
    }

    fn acceptModelPickerSelection(self: *App) !void {
        const query = parseModelPickerQuery(self.input_buffer.items) orelse return;
        const total = self.modelPickerMatchCount(query);
        if (total == 0) {
            try self.setNotice("No model matches the current filter");
            return;
        }

        if (self.model_picker_index >= total) self.model_picker_index = total - 1;
        const selected = self.modelPickerNthMatch(query, self.model_picker_index) orelse return;

        try self.app_state.setSelectedModel(self.allocator, selected.id);
        try self.app_state.saveToPath(self.allocator, self.paths.state_path);
        try self.setNoticeFmt("Model set to {s}", .{selected.id});

        self.input_buffer.clearRetainingCapacity();
        self.input_cursor = 0;
        self.model_picker_open = false;
        self.model_picker_index = 0;
        self.model_picker_scroll = 0;
    }

    fn modelPickerLineCount(self: *App, terminal_lines: usize) usize {
        if (!self.model_picker_open) return 0;

        const query = parseModelPickerQuery(self.input_buffer.items) orelse return 0;
        const total = self.modelPickerMatchCount(query);
        const max_rows = self.modelPickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);
        return 1 + shown_rows;
    }

    fn filePickerLineCount(self: *App, terminal_lines: usize) usize {
        if (!self.file_picker_open) return 0;

        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse return 0;
        const total = self.filePickerMatchCount(query);
        const max_rows = self.filePickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);
        return 1 + shown_rows;
    }

    fn commandPickerLineCount(self: *App, terminal_lines: usize) usize {
        if (!self.command_picker_open) return 0;

        const query = self.commandPickerQueryForKind(self.command_picker_kind) orelse return 0;
        const total = self.commandPickerMatchCount(query);
        const max_rows = self.commandPickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);
        return 1 + shown_rows;
    }

    fn pickerLineCount(self: *App, terminal_lines: usize) usize {
        if (self.model_picker_open) return self.modelPickerLineCount(terminal_lines);
        if (self.command_picker_open) return self.commandPickerLineCount(terminal_lines);
        if (self.file_picker_open) return self.filePickerLineCount(terminal_lines);
        return 0;
    }

    fn modelPickerMaxRows(_: *App, terminal_lines: usize) usize {
        const budget = @max(@as(usize, 3), terminal_lines / 5);
        return @min(MODEL_PICKER_MAX_ROWS, budget);
    }

    fn filePickerMaxRows(_: *App, terminal_lines: usize) usize {
        const budget = @max(@as(usize, 3), terminal_lines / 5);
        return @min(FILE_PICKER_MAX_ROWS, budget);
    }

    fn commandPickerMaxRows(_: *App, terminal_lines: usize) usize {
        const budget = @max(@as(usize, 3), terminal_lines / 5);
        return @min(COMMAND_PICKER_MAX_ROWS, budget);
    }

    fn renderModelPicker(self: *App, writer: *std.Io.Writer, width: usize, terminal_lines: usize, palette: Palette) !void {
        const query = parseModelPickerQuery(self.input_buffer.items) orelse return;
        const total = self.modelPickerMatchCount(query);
        const max_rows = self.modelPickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);

        if (total > 0) {
            if (self.model_picker_index >= total) self.model_picker_index = total - 1;
            if (self.model_picker_index < self.model_picker_scroll) {
                self.model_picker_scroll = self.model_picker_index;
            } else if (self.model_picker_index >= self.model_picker_scroll + shown_rows) {
                self.model_picker_scroll = self.model_picker_index - shown_rows + 1;
            }
            const max_scroll = total - shown_rows;
            if (self.model_picker_scroll > max_scroll) self.model_picker_scroll = max_scroll;
        } else {
            self.model_picker_index = 0;
            self.model_picker_scroll = 0;
        }

        const header_text = try std.fmt.allocPrint(
            self.allocator,
            "model picker ({d}) provider:{s} query:{s}",
            .{ total, self.app_state.selected_provider_id, if (query.len == 0) "*" else query },
        );
        defer self.allocator.free(header_text);
        const header_line = try truncateLineAlloc(self.allocator, header_text, width);
        defer self.allocator.free(header_line);
        try writer.print("{s}{s}{s}\n", .{ palette.accent, header_line, palette.reset });

        if (total == 0) {
            const empty_line = try truncateLineAlloc(self.allocator, "  no matches", width);
            defer self.allocator.free(empty_line);
            try writer.print("{s}{s}{s}\n", .{ palette.dim, empty_line, palette.reset });
            return;
        }

        const end_index = @min(self.model_picker_scroll + shown_rows, total);
        var index = self.model_picker_scroll;
        while (index < end_index) : (index += 1) {
            const model = self.modelPickerNthMatch(query, index) orelse continue;
            const selected = index == self.model_picker_index;
            const marker = if (selected) ">" else " ";
            const row_color = if (selected) palette.accent else palette.dim;

            const row_text = if (std.mem.eql(u8, model.id, model.name))
                try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ marker, model.id })
            else
                try std.fmt.allocPrint(self.allocator, "{s} {s} ({s})", .{ marker, model.id, model.name });
            defer self.allocator.free(row_text);

            const row_line = try truncateLineAlloc(self.allocator, row_text, width);
            defer self.allocator.free(row_line);
            try writer.print("{s}{s}{s}\n", .{ row_color, row_line, palette.reset });
        }
    }

    fn filePickerMatchCount(self: *App, query: []const u8) usize {
        var count: usize = 0;
        for (self.file_index.items) |path| {
            if (filePathMatchesQuery(path, query)) count += 1;
        }
        return count;
    }

    fn commandPickerMatchCount(self: *App, query: []const u8) usize {
        var count: usize = 0;
        switch (self.command_picker_kind) {
            .slash_commands => {
                for (BUILTIN_COMMANDS) |entry| {
                    if (commandMatchesQuery(entry, query)) count += 1;
                }
            },
            .quick_actions => {
                for (QUICK_ACTIONS) |entry| {
                    if (quickActionMatchesQuery(entry, query)) count += 1;
                }
            },
            .conversation_switch => {
                for (self.app_state.conversations.items, 0..) |*conversation, index| {
                    if (!shouldIncludeConversationInSessionOrder(
                        self.app_state.conversations.items,
                        index,
                        self.app_state.current_index,
                        false,
                    )) continue;
                    if (conversationMatchesQuery(conversation, query)) count += 1;
                }
            },
            .provider_options => {
                count = self.providerPickerMatchCount(query);
            },
        }
        return count;
    }

    fn filePickerNthMatch(self: *App, query: []const u8, target_index: usize) ?[]const u8 {
        var seen: usize = 0;
        for (self.file_index.items) |path| {
            if (!filePathMatchesQuery(path, query)) continue;
            if (seen == target_index) return path;
            seen += 1;
        }
        return null;
    }

    fn commandPickerNthMatch(self: *App, query: []const u8, target_index: usize) ?BuiltinCommandEntry {
        var seen: usize = 0;
        for (BUILTIN_COMMANDS) |entry| {
            if (!commandMatchesQuery(entry, query)) continue;
            if (seen == target_index) return entry;
            seen += 1;
        }
        _ = self;
        return null;
    }

    fn quickActionPickerNthMatch(_: *App, query: []const u8, target_index: usize) ?QuickActionEntry {
        var seen: usize = 0;
        for (QUICK_ACTIONS) |entry| {
            if (!quickActionMatchesQuery(entry, query)) continue;
            if (seen == target_index) return entry;
            seen += 1;
        }
        return null;
    }

    fn providerPickerMatchCount(self: *App, query: []const u8) usize {
        var count: usize = 0;
        var included_openai_auth_options = false;
        for (self.catalog.providers.items) |provider| {
            const provider_entry: ProviderPickerEntry = .{
                .command_suffix = provider.id,
                .description = provider.name,
            };
            if (providerPickerEntryMatches(provider_entry, query)) count += 1;

            if (!included_openai_auth_options and std.mem.eql(u8, provider.id, "openai")) {
                included_openai_auth_options = true;
                for (PROVIDER_PICKER_OPENAI_AUTH_OPTIONS) |auth_entry| {
                    if (providerPickerEntryMatches(auth_entry, query)) count += 1;
                }
            }
        }
        return count;
    }

    fn providerPickerNthMatch(self: *App, query: []const u8, target_index: usize) ?ProviderPickerEntry {
        var seen: usize = 0;
        var included_openai_auth_options = false;
        for (self.catalog.providers.items) |provider| {
            const provider_entry: ProviderPickerEntry = .{
                .command_suffix = provider.id,
                .description = provider.name,
            };
            if (providerPickerEntryMatches(provider_entry, query)) {
                if (seen == target_index) return provider_entry;
                seen += 1;
            }

            if (!included_openai_auth_options and std.mem.eql(u8, provider.id, "openai")) {
                included_openai_auth_options = true;
                for (PROVIDER_PICKER_OPENAI_AUTH_OPTIONS) |auth_entry| {
                    if (!providerPickerEntryMatches(auth_entry, query)) continue;
                    if (seen == target_index) return auth_entry;
                    seen += 1;
                }
            }
        }
        return null;
    }

    fn moveFilePickerSelection(self: *App, delta: i32) void {
        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.filePickerMatchCount(query);
        if (total == 0) {
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
            return;
        }

        if (delta < 0) {
            if (self.file_picker_index > 0) self.file_picker_index -= 1;
        } else if (delta > 0) {
            if (self.file_picker_index + 1 < total) self.file_picker_index += 1;
        }
    }

    fn moveCommandPickerSelection(self: *App, delta: i32) void {
        const query = self.commandPickerQueryForKind(self.command_picker_kind) orelse return;
        const total = self.commandPickerMatchCount(query);
        if (total == 0) {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            return;
        }

        if (delta < 0) {
            if (self.command_picker_index > 0) self.command_picker_index -= 1;
        } else if (delta > 0) {
            if (self.command_picker_index + 1 < total) self.command_picker_index += 1;
        }
    }

    fn acceptFilePickerSelection(self: *App) !void {
        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.filePickerMatchCount(query);
        if (total == 0) {
            try self.setNotice("No file matches current @query");
            return;
        }

        if (self.file_picker_index >= total) self.file_picker_index = total - 1;
        const selected = self.filePickerNthMatch(query, self.file_picker_index) orelse return;

        try self.insertSelectedFilePathAtCursor(selected);
        self.file_picker_open = false;
        self.file_picker_index = 0;
        self.file_picker_scroll = 0;
        try self.setNoticeFmt("Inserted @{s}", .{selected});
    }

    fn acceptCommandPickerSelection(self: *App) !void {
        const query = self.commandPickerQueryForKind(self.command_picker_kind) orelse return;
        const total = self.commandPickerMatchCount(query);
        if (total == 0) {
            if (self.command_picker_kind == .quick_actions) {
                try self.setNotice("No quick action matches current query");
            } else if (self.command_picker_kind == .conversation_switch) {
                try self.setNotice("No conversation matches current query");
            } else {
                try self.setNotice("No slash command matches current query");
            }
            return;
        }

        if (self.command_picker_index >= total) self.command_picker_index = total - 1;
        if (self.command_picker_kind == .quick_actions) {
            const selected = self.quickActionPickerNthMatch(query, self.command_picker_index) orelse return;
            self.command_picker_open = false;
            self.command_picker_kind = .slash_commands;
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            self.input_buffer.clearRetainingCapacity();
            self.input_cursor = 0;
            try self.executeQuickAction(selected);
        } else if (self.command_picker_kind == .provider_options) {
            const selected = self.providerPickerNthMatch(query, self.command_picker_index) orelse return;
            self.input_buffer.clearRetainingCapacity();
            try self.input_buffer.appendSlice(self.allocator, "/provider ");
            try self.input_buffer.appendSlice(self.allocator, selected.command_suffix);
            self.input_cursor = self.input_buffer.items.len;
            self.command_picker_open = false;
            self.command_picker_kind = .slash_commands;
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            try self.setNoticeFmt("Inserted /provider {s}", .{selected.command_suffix});
            self.syncPickersFromInput();
        } else if (self.command_picker_kind == .conversation_switch) {
            var ordered_matches = try collectConversationSwitchMatchOrder(
                self.allocator,
                self.app_state.conversations.items,
                self.app_state.current_index,
                query,
                false,
            );
            defer ordered_matches.deinit(self.allocator);
            if (ordered_matches.items.len == 0) return;
            if (self.command_picker_index >= ordered_matches.items.len) {
                self.command_picker_index = ordered_matches.items.len - 1;
            }
            const selected = &self.app_state.conversations.items[ordered_matches.items[self.command_picker_index]];
            _ = try self.app_state.switchConversation(self.allocator, selected.id);
            self.scroll_lines = 0;
            self.ensureCurrentConversationVisibleInStrip();
            try self.app_state.saveToPath(self.allocator, self.paths.state_path);

            self.input_buffer.clearRetainingCapacity();
            self.input_cursor = 0;
            self.command_picker_open = false;
            self.command_picker_kind = .slash_commands;
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
            try self.setNoticeFmt("Switched to conversation: {s}", .{selected.id});
        } else {
            const selected = self.commandPickerNthMatch(query, self.command_picker_index) orelse return;

            self.input_buffer.clearRetainingCapacity();
            try self.input_buffer.appendSlice(self.allocator, "/");
            try self.input_buffer.appendSlice(self.allocator, selected.name);
            if (selected.insert_trailing_space) {
                try self.input_buffer.append(self.allocator, ' ');
            }
            self.input_cursor = self.input_buffer.items.len;
            self.command_picker_open = false;
            self.command_picker_kind = .slash_commands;
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;

            try self.setNoticeFmt("Inserted /{s}", .{selected.name});
            self.syncPickersFromInput();
        }
    }

    fn executeQuickAction(self: *App, action: QuickActionEntry) !void {
        switch (action.id) {
            .new_chat => {
                try self.handleCommand("/new");
            },
            .open_conversation_switch => {
                try self.openConversationSwitchPicker();
            },
            .open_model_picker => {
                try self.setInputBufferTo("/model ");
                self.syncPickersFromInput();
                try self.setNotice("Opened model picker");
            },
            .open_provider_command => {
                try self.setInputBufferTo("/provider ");
                self.syncPickersFromInput();
                try self.setNotice("Inserted /provider");
            },
            .compact_session => {
                try self.handleCommand("/compact");
            },
            .refresh_models_cache => {
                try self.handleCommand("/models refresh");
            },
            .refresh_file_index => {
                try self.handleCommand("/files refresh");
            },
            .toggle_ui_density => {
                if (self.compact_mode) {
                    try self.handleCommand("/ui comfy");
                } else {
                    try self.handleCommand("/ui compact");
                }
            },
            .toggle_theme => {
                self.theme = switch (self.theme) {
                    .codex => .plain,
                    .plain => .forest,
                    .forest => .codex,
                };
                try self.setNoticeFmt("Theme set to {s}", .{@tagName(self.theme)});
            },
            .show_help => {
                try self.handleCommand("/help");
            },
        }
    }

    fn insertSelectedFilePathAtCursor(self: *App, path: []const u8) !void {
        const rewritten = try rewriteInputWithSelectedAtPath(self.allocator, self.input_buffer.items, self.input_cursor, path);
        defer self.allocator.free(rewritten.text);

        self.input_buffer.clearRetainingCapacity();
        try self.input_buffer.appendSlice(self.allocator, rewritten.text);
        self.input_cursor = rewritten.cursor;
    }

    fn renderFilePicker(self: *App, writer: *std.Io.Writer, width: usize, terminal_lines: usize, palette: Palette) !void {
        const query = currentAtTokenQuery(self.input_buffer.items, self.input_cursor) orelse return;
        const total = self.filePickerMatchCount(query);
        const max_rows = self.filePickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);

        if (total > 0) {
            if (self.file_picker_index >= total) self.file_picker_index = total - 1;
            if (self.file_picker_index < self.file_picker_scroll) {
                self.file_picker_scroll = self.file_picker_index;
            } else if (self.file_picker_index >= self.file_picker_scroll + shown_rows) {
                self.file_picker_scroll = self.file_picker_index - shown_rows + 1;
            }
            const max_scroll = total - shown_rows;
            if (self.file_picker_scroll > max_scroll) self.file_picker_scroll = max_scroll;
        } else {
            self.file_picker_index = 0;
            self.file_picker_scroll = 0;
        }

        const header_text = try std.fmt.allocPrint(
            self.allocator,
            "file picker ({d}) query:{s}",
            .{ total, if (query.len == 0) "*" else query },
        );
        defer self.allocator.free(header_text);
        const header_line = try truncateLineAlloc(self.allocator, header_text, width);
        defer self.allocator.free(header_line);
        try writer.print("{s}{s}{s}\n", .{ palette.accent, header_line, palette.reset });

        if (total == 0) {
            const empty_line = try truncateLineAlloc(self.allocator, "  no matches", width);
            defer self.allocator.free(empty_line);
            try writer.print("{s}{s}{s}\n", .{ palette.dim, empty_line, palette.reset });
            return;
        }

        const end_index = @min(self.file_picker_scroll + shown_rows, total);
        var index = self.file_picker_scroll;
        while (index < end_index) : (index += 1) {
            const selected_path = self.filePickerNthMatch(query, index) orelse continue;
            const selected = index == self.file_picker_index;
            const marker = if (selected) ">" else " ";
            const row_color = if (selected) palette.accent else palette.dim;

            const row_text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ marker, selected_path });
            defer self.allocator.free(row_text);
            const row_line = try truncateLineAlloc(self.allocator, row_text, width);
            defer self.allocator.free(row_line);
            try writer.print("{s}{s}{s}\n", .{ row_color, row_line, palette.reset });
        }
    }

    fn renderCommandPicker(self: *App, writer: *std.Io.Writer, width: usize, terminal_lines: usize, palette: Palette) !void {
        const query = self.commandPickerQueryForKind(self.command_picker_kind) orelse return;
        var ordered_conversation_matches: std.ArrayList(usize) = .empty;
        defer ordered_conversation_matches.deinit(self.allocator);
        const total = switch (self.command_picker_kind) {
            .conversation_switch => blk: {
                ordered_conversation_matches = try collectConversationSwitchMatchOrder(
                    self.allocator,
                    self.app_state.conversations.items,
                    self.app_state.current_index,
                    query,
                    false,
                );
                break :blk ordered_conversation_matches.items.len;
            },
            else => self.commandPickerMatchCount(query),
        };
        const max_rows = self.commandPickerMaxRows(terminal_lines);
        const shown_rows = if (total == 0) @as(usize, 1) else @min(total, max_rows);

        if (total > 0) {
            if (self.command_picker_index >= total) self.command_picker_index = total - 1;
            if (self.command_picker_index < self.command_picker_scroll) {
                self.command_picker_scroll = self.command_picker_index;
            } else if (self.command_picker_index >= self.command_picker_scroll + shown_rows) {
                self.command_picker_scroll = self.command_picker_index - shown_rows + 1;
            }
            const max_scroll = total - shown_rows;
            if (self.command_picker_scroll > max_scroll) self.command_picker_scroll = max_scroll;
        } else {
            self.command_picker_index = 0;
            self.command_picker_scroll = 0;
        }

        const header_text = try std.fmt.allocPrint(
            self.allocator,
            "{s} ({d}) query:{s}",
            .{
                if (self.command_picker_kind == .conversation_switch)
                    "conversation sessions"
                else if (self.command_picker_kind == .quick_actions)
                    "command palette"
                else if (self.command_picker_kind == .provider_options)
                    "provider picker"
                else
                    "command picker",
                total,
                if (query.len == 0) "*" else query,
            },
        );
        defer self.allocator.free(header_text);
        const header_line = try truncateLineAlloc(self.allocator, header_text, width);
        defer self.allocator.free(header_line);
        try writer.print("{s}{s}{s}\n", .{ palette.accent, header_line, palette.reset });

        if (total == 0) {
            const empty_line = try truncateLineAlloc(self.allocator, "  no matches", width);
            defer self.allocator.free(empty_line);
            try writer.print("{s}{s}{s}\n", .{ palette.dim, empty_line, palette.reset });
            return;
        }

        const end_index = @min(self.command_picker_scroll + shown_rows, total);
        const now_ms = std.time.milliTimestamp();
        var index = self.command_picker_scroll;
        while (index < end_index) : (index += 1) {
            const is_selected = index == self.command_picker_index;
            const marker = if (is_selected) ">" else " ";
            const row_color = if (is_selected) palette.accent else palette.dim;
            const row_text = if (self.command_picker_kind == .quick_actions) blk: {
                const selected_entry = self.quickActionPickerNthMatch(query, index) orelse continue;
                break :blk try std.fmt.allocPrint(
                    self.allocator,
                    "{s} {s}  {s}",
                    .{ marker, selected_entry.label, selected_entry.description },
                );
            } else if (self.command_picker_kind == .conversation_switch) blk: {
                const conversation = &self.app_state.conversations.items[ordered_conversation_matches.items[index]];
                const age = conversationRelativeAge(now_ms, conversationTimestampMs(conversation));
                const age_label = try conversationAgeLabelAlloc(self.allocator, age);
                defer self.allocator.free(age_label);
                const title_max_width = sessionPickerTitleMaxWidth(width, conversation.id.len, age_label.len);
                const title = if (title_max_width == 0)
                    try self.allocator.dupe(u8, "")
                else
                    try truncateLineAlloc(self.allocator, conversation.title, title_max_width);
                defer self.allocator.free(title);
                const current_marker = if (self.app_state.current_index < self.app_state.conversations.items.len and
                    std.mem.eql(u8, self.app_state.currentConversationConst().id, conversation.id)) "*" else " ";
                break :blk try std.fmt.allocPrint(
                    self.allocator,
                    "{s}{s} {s}  {s}  {s}",
                    .{ marker, current_marker, conversation.id, age_label, title },
                );
            } else if (self.command_picker_kind == .provider_options) blk: {
                const selected_entry = self.providerPickerNthMatch(query, index) orelse continue;
                break :blk try std.fmt.allocPrint(
                    self.allocator,
                    "{s} /provider {s}  {s}",
                    .{ marker, selected_entry.command_suffix, selected_entry.description },
                );
            } else blk: {
                const selected_entry = self.commandPickerNthMatch(query, index) orelse continue;
                break :blk try std.fmt.allocPrint(
                    self.allocator,
                    "{s} /{s}  {s}",
                    .{ marker, selected_entry.name, selected_entry.description },
                );
            };
            defer self.allocator.free(row_text);
            const row_line = try truncateLineAlloc(self.allocator, row_text, width);
            defer self.allocator.free(row_line);
            try writer.print("{s}{s}{s}\n", .{ row_color, row_line, palette.reset });
        }
    }

    fn refreshFileIndex(self: *App) !void {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rg", "--files" },
            .cwd = ".",
            .max_output_bytes = FILE_INDEX_MAX_OUTPUT_BYTES,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code != 0) return error.FileIndexRefreshFailed,
            else => return error.FileIndexRefreshFailed,
        }

        for (self.file_index.items) |path| self.allocator.free(path);
        self.file_index.clearRetainingCapacity();

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (line.len == 0) continue;
            try self.file_index.append(self.allocator, try self.allocator.dupe(u8, line));
        }
    }

    fn ensureFileIndexLoaded(self: *App) void {
        if (self.file_index_loaded or self.file_index_attempted) return;
        self.file_index_attempted = true;
        self.refreshFileIndex() catch return;
        self.file_index_loaded = true;
    }
};

const Palette = struct {
    reset: []const u8,
    dim: []const u8,
    header: []const u8,
    accent: []const u8,
    user: []const u8,
    assistant: []const u8,
    system: []const u8,
    diff_add: []const u8,
    diff_remove: []const u8,
    diff_meta: []const u8,
};

const CursorPlacement = struct {
    row: usize,
    col: usize,
};

const InputView = struct {
    text: []u8,
    cursor_col: usize,
};

fn computeInputCursorPlacement(
    width: usize,
    lines: usize,
    compact_mode: bool,
    viewport_height: usize,
    picker_lines: usize,
    input_cursor_col: usize,
) CursorPlacement {
    const header_lines: usize = if (compact_mode) 2 else 3;
    const input_row_unclamped = header_lines + 1 + viewport_height + 1 + 1 + picker_lines + 1;
    const input_row = std.math.clamp(input_row_unclamped, @as(usize, 1), lines);

    // Prompt prefix is always "[INS]> " or "[NOR]> " (6 chars + trailing space).
    const prompt_visible_len: usize = 7;
    const input_col_unclamped = prompt_visible_len + input_cursor_col + 1;
    const input_col = std.math.clamp(input_col_unclamped, @as(usize, 1), width);

    return .{
        .row = input_row,
        .col = input_col,
    };
}

fn paletteForTheme(theme: Theme) Palette {
    return switch (theme) {
        .codex => .{
            .reset = "\x1b[0m",
            .dim = "\x1b[38;5;245m",
            .header = "\x1b[38;5;110m",
            .accent = "\x1b[38;5;117m",
            .user = "\x1b[38;5;215m",
            .assistant = "\x1b[38;5;114m",
            .system = "\x1b[38;5;146m",
            .diff_add = "\x1b[38;5;114m",
            .diff_remove = "\x1b[38;5;203m",
            .diff_meta = "\x1b[38;5;180m",
        },
        .plain => .{
            .reset = "",
            .dim = "",
            .header = "",
            .accent = "",
            .user = "",
            .assistant = "",
            .system = "",
            .diff_add = "",
            .diff_remove = "",
            .diff_meta = "",
        },
        .forest => .{
            .reset = "\x1b[0m",
            .dim = "\x1b[38;5;245m",
            .header = "\x1b[38;5;71m",
            .accent = "\x1b[38;5;114m",
            .user = "\x1b[38;5;151m",
            .assistant = "\x1b[38;5;108m",
            .system = "\x1b[38;5;145m",
            .diff_add = "\x1b[38;5;114m",
            .diff_remove = "\x1b[38;5;203m",
            .diff_meta = "\x1b[38;5;151m",
        },
    };
}

fn writeRule(writer: *std.Io.Writer, width: usize, palette: Palette, compact_mode: bool) !void {
    const rule_width: usize = if (compact_mode and width > 88) 88 else width;
    try writer.writeAll(palette.dim);
    try writer.splatByteAll('-', rule_width);
    try writer.writeAll(palette.reset);
    try writer.writeByte('\n');
}

fn roleColor(role: Role, palette: Palette) []const u8 {
    return switch (role) {
        .user => palette.user,
        .assistant => palette.assistant,
        .system => palette.system,
    };
}

fn appendMessageBlock(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    message: anytype,
    width: usize,
    palette: Palette,
    compact_mode: bool,
    content_override: ?[]const u8,
) !void {
    _ = compact_mode;

    const marker, const continuation, const color = switch (message.role) {
        .user => .{ "› ", "  ", palette.user },
        .assistant => .{ "• ", "  ", palette.assistant },
        .system => .{ "○ ", "  ", palette.system },
    };

    const rendered_content = content_override orelse messageDisplayContent(message);
    if (shouldRenderDiffMode(message, rendered_content)) {
        _ = try writeWrappedPrefixedDiff(
            writer,
            rendered_content,
            width,
            marker,
            continuation,
            color,
            palette,
            palette.reset,
        );
    } else {
        _ = try writeWrappedPrefixedMarkdown(
            allocator,
            writer,
            rendered_content,
            width,
            marker,
            continuation,
            color,
            palette,
            palette.reset,
        );
    }
    try writer.writeByte('\n');
}

fn messageDisplayContent(message: anytype) []const u8 {
    if (message.content.len == 0) return "...";

    if (message.role == .system) {
        if (std.mem.startsWith(u8, message.content, FILE_INJECT_HEADER) or
            std.mem.startsWith(u8, message.content, SKILL_INJECT_HEADER) or
            std.mem.startsWith(u8, message.content, AGENTS_CONTEXT_HEADER) or
            std.mem.startsWith(u8, message.content, SKILLS_CONTEXT_HEADER) or
            std.mem.startsWith(u8, message.content, COMPACT_SUMMARY_HEADER))
        {
            const line_end = std.mem.indexOfScalar(u8, message.content, '\n') orelse message.content.len;
            return message.content[0..line_end];
        }
    }

    return message.content;
}

fn streamTaskTitle(task: StreamTask) []const u8 {
    return switch (task) {
        .idle => "Idle",
        .thinking => "Thinking",
        .responding => "Responding",
        .compacting => "Compacting",
        .running_read => "Running READ",
        .running_list_dir => "Running LIST_DIR",
        .running_read_file => "Running READ_FILE",
        .running_grep_files => "Running GREP_FILES",
        .running_project_search => "Running PROJECT_SEARCH",
        .running_apply_patch => "Running APPLY_PATCH",
        .running_exec_command => "Running EXEC_COMMAND",
        .running_write_stdin => "Running WRITE_STDIN",
        .running_web_search => "Running WEB_SEARCH",
        .running_view_image => "Running VIEW_IMAGE",
        .running_skill => "Running SKILL",
    };
}

fn streamElapsedMs(started_ms: i64, now_ms: i64) i64 {
    if (started_ms <= 0) return 0;
    return @max(@as(i64, 0), now_ms - started_ms);
}

fn streamStatusHeader(task_title: []const u8) []const u8 {
    if (std.mem.eql(u8, task_title, "Idle")) return "Working";
    if (std.mem.eql(u8, task_title, "Thinking")) return "Working";
    if (std.mem.eql(u8, task_title, "Responding")) return "Working";
    return task_title;
}

fn buildStreamingNotice(
    allocator: std.mem.Allocator,
    task_title: []const u8,
    started_ms: i64,
    now_ms: i64,
) ![]u8 {
    const elapsed_ms = streamElapsedMs(started_ms, now_ms);
    const elapsed_seconds = @divFloor(elapsed_ms, 1000);
    const header = streamStatusHeader(task_title);

    return std.fmt.allocPrint(
        allocator,
        "{s} ({d}s • esc to interrupt)",
        .{ header, elapsed_seconds },
    );
}

fn buildWorkingPlaceholder(
    allocator: std.mem.Allocator,
    task_title: []const u8,
    started_ms: i64,
    now_ms: i64,
) ![]u8 {
    const elapsed_ms = streamElapsedMs(started_ms, now_ms);
    const elapsed_seconds = @divFloor(elapsed_ms, 1000);
    const header = streamStatusHeader(task_title);

    return std.fmt.allocPrint(
        allocator,
        "{s} ({d}s • esc to interrupt)",
        .{ header, elapsed_seconds },
    );
}

fn autoCompactPercentLeft(conversation: *const Conversation) ?i64 {
    const context_window = conversation.model_context_window orelse return null;
    if (conversation.last_token_usage.isZero()) return null;
    return conversation.last_token_usage.percentOfContextWindowRemaining(context_window);
}

fn normalizeAutoCompactPercentLeft(percent_left: i64) i64 {
    return std.math.clamp(percent_left, @as(i64, 0), @as(i64, 100));
}

fn isCompactionSourceMessage(message: anytype) bool {
    if (message.role != .user and message.role != .assistant) return false;
    const trimmed = std.mem.trim(u8, message.content, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.startsWith(u8, trimmed, COMPACT_NOTE_HEADER)) return false;
    if (std.mem.startsWith(u8, trimmed, COMPACT_SUMMARY_HEADER)) return false;
    if (parseAssistantToolCall(trimmed) != null) return false;
    return true;
}

fn countCompactionSourceMessages(messages: []const Message) usize {
    var count: usize = 0;
    for (messages) |message| {
        if (isCompactionSourceMessage(message)) count += 1;
    }
    return count;
}

fn appendCompactedMessageOwned(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Message),
    role: Role,
    content: []const u8,
    timestamp_ms: i64,
) !void {
    try list.append(allocator, .{
        .role = role,
        .content = try allocator.dupe(u8, content),
        .timestamp_ms = timestamp_ms,
    });
}

fn appendCompactedMessageCopy(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Message),
    message: Message,
) !void {
    try appendCompactedMessageOwned(allocator, list, message.role, message.content, message.timestamp_ms);
}

fn roleLabelForCompact(role: Role) []const u8 {
    return switch (role) {
        .user => "User",
        .assistant => "Assistant",
        .system => "System",
    };
}

fn compactPreviewAlloc(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "(empty)");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var truncated = false;
    var previous_was_space = false;
    for (trimmed) |byte| {
        var normalized = byte;
        if (normalized == '\n' or normalized == '\r' or normalized == '\t') normalized = ' ';
        if (normalized < 32) continue;

        if (normalized == ' ') {
            if (out.items.len == 0 or previous_was_space) continue;
            if (out.items.len >= max_chars) {
                truncated = true;
                break;
            }
            try out.append(allocator, ' ');
            previous_was_space = true;
            continue;
        }

        if (out.items.len >= max_chars) {
            truncated = true;
            break;
        }
        try out.append(allocator, normalized);
        previous_was_space = false;
    }

    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') {
        _ = out.pop();
    }

    if (out.items.len == 0) {
        return allocator.dupe(u8, "(empty)");
    }

    if (truncated) {
        try out.appendSlice(allocator, "...");
    }

    return out.toOwnedSlice(allocator);
}

fn shouldRenderDiffMode(message: anytype, text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.mem.indexOf(u8, text, "*** Begin Patch") != null) return true;
    if (std.mem.indexOf(u8, text, "```diff") != null) return true;
    if (std.mem.indexOf(u8, text, "```patch") != null) return true;
    if (std.mem.indexOf(u8, text, "```udiff") != null) return true;
    if (std.mem.indexOf(u8, text, "```gitdiff") != null) return true;

    if (message.role == .system and std.mem.startsWith(u8, text, "[apply-patch-result]")) {
        return std.mem.indexOf(u8, text, "diff_preview:") != null;
    }

    return false;
}

fn diffLineColor(line: []const u8, palette: Palette) []const u8 {
    if (line.len == 0) return "";
    if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) return palette.diff_add;
    if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) return palette.diff_remove;
    if (std.mem.startsWith(u8, line, "@@") or std.mem.startsWith(u8, line, "*** ")) return palette.diff_meta;
    return "";
}

const DiffRenderState = struct {
    in_fenced_block: bool = false,
    fenced_block_is_diff: bool = false,
};

fn diffRenderColorForLine(state: *DiffRenderState, line: []const u8, palette: Palette) []const u8 {
    const trimmed_leading = std.mem.trimLeft(u8, line, " \t");
    if (isCodeFenceLine(trimmed_leading)) {
        if (state.in_fenced_block) {
            state.in_fenced_block = false;
            state.fenced_block_is_diff = false;
        } else {
            state.in_fenced_block = true;
            state.fenced_block_is_diff = isDiffFenceLanguage(codeFenceLanguageToken(trimmed_leading));
        }
        return palette.diff_meta;
    }

    if (state.in_fenced_block) {
        if (state.fenced_block_is_diff) {
            const diff_color = diffLineColor(trimmed_leading, palette);
            if (diff_color.len > 0) return diff_color;
            return palette.dim;
        }
        return palette.accent;
    }

    return diffLineColor(trimmed_leading, palette);
}

fn isCodeFenceLine(trimmed_line: []const u8) bool {
    return std.mem.startsWith(u8, trimmed_line, "```");
}

fn codeFenceLanguageToken(trimmed_line: []const u8) []const u8 {
    if (!isCodeFenceLine(trimmed_line)) return "";
    const after_ticks = std.mem.trimLeft(u8, trimmed_line["```".len..], " \t");
    if (after_ticks.len == 0) return "";

    var end: usize = 0;
    while (end < after_ticks.len and !std.ascii.isWhitespace(after_ticks[end])) : (end += 1) {}
    return after_ticks[0..end];
}

fn isDiffFenceLanguage(language: []const u8) bool {
    if (language.len == 0) return false;
    return std.ascii.eqlIgnoreCase(language, "diff") or
        std.ascii.eqlIgnoreCase(language, "patch") or
        std.ascii.eqlIgnoreCase(language, "udiff") or
        std.ascii.eqlIgnoreCase(language, "gitdiff");
}

fn writeWrappedPrefixed(
    writer: *std.Io.Writer,
    text: []const u8,
    width: usize,
    first_prefix: []const u8,
    next_prefix: []const u8,
    prefix_color: []const u8,
    reset: []const u8,
) !usize {
    var line_count: usize = 0;
    var first_line = true;

    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| {
        const para = std.mem.trimRight(u8, paragraph, " ");
        if (para.len == 0) {
            const prefix = if (first_line) first_prefix else next_prefix;
            try writer.print("{s}{s}{s}\n", .{ prefix_color, prefix, reset });
            first_line = false;
            line_count += 1;
            continue;
        }

        var start: usize = 0;
        while (start < para.len) {
            const prefix = if (first_line) first_prefix else next_prefix;
            const prefix_len = prefix.len;
            const wrap_width = @max(@as(usize, 1), width -| prefix_len);
            const max_end = @min(start + wrap_width, para.len);

            var end = max_end;
            if (max_end < para.len) {
                var cursor = max_end;
                while (cursor > start and para[cursor - 1] != ' ') : (cursor -= 1) {}
                if (cursor > start) end = cursor - 1;
            }
            if (end <= start) end = max_end;

            try writer.print("{s}{s}{s}", .{ prefix_color, prefix, reset });
            try writer.writeAll(std.mem.trimRight(u8, para[start..end], " "));
            try writer.writeByte('\n');

            line_count += 1;
            first_line = false;
            start = end;
            while (start < para.len and para[start] == ' ') : (start += 1) {}
        }
    }

    return line_count;
}

const MarkdownLineKind = enum {
    plain,
    heading,
    quote,
    list,
    code,
    fence,
};

const MarkdownRenderState = struct {
    in_fenced_block: bool = false,
};

const MarkdownPreparedLine = struct {
    text: []u8,
    kind: MarkdownLineKind,
    wrap_on_words: bool = true,
    supports_inline_code: bool = true,

    fn deinit(self: *MarkdownPreparedLine, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const InlineMarkdownState = struct {
    in_code: bool = false,
};

fn writeWrappedPrefixedMarkdown(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    text: []const u8,
    width: usize,
    first_prefix: []const u8,
    next_prefix: []const u8,
    prefix_color: []const u8,
    palette: Palette,
    reset: []const u8,
) !usize {
    var line_count: usize = 0;
    var first_line = true;
    var markdown_state: MarkdownRenderState = .{};

    var raw_lines = std.mem.splitScalar(u8, text, '\n');
    while (raw_lines.next()) |raw_line| {
        var prepared = try prepareMarkdownLineAlloc(allocator, raw_line, &markdown_state);
        defer prepared.deinit(allocator);

        const line_text = std.mem.trimRight(u8, prepared.text, " ");
        if (line_text.len == 0) {
            const prefix = if (first_line) first_prefix else next_prefix;
            try writer.print("{s}{s}{s}\n", .{ prefix_color, prefix, reset });
            first_line = false;
            line_count += 1;
            continue;
        }

        var inline_state: InlineMarkdownState = .{};
        var start: usize = 0;
        while (start < line_text.len) {
            const prefix = if (first_line) first_prefix else next_prefix;
            const prefix_len = prefix.len;
            const wrap_width = @max(@as(usize, 1), width -| prefix_len);
            const max_end = @min(start + wrap_width, line_text.len);

            var end = max_end;
            if (prepared.wrap_on_words and max_end < line_text.len) {
                var cursor = max_end;
                while (cursor > start and line_text[cursor - 1] != ' ') : (cursor -= 1) {}
                if (cursor > start) end = cursor - 1;
            }
            if (end <= start) end = max_end;

            var segment = line_text[start..end];
            if (prepared.wrap_on_words) {
                segment = std.mem.trimRight(u8, segment, " ");
            }

            try writer.print("{s}{s}{s}", .{ prefix_color, prefix, reset });
            try writeMarkdownSegmentStyled(
                writer,
                segment,
                prepared,
                &inline_state,
                palette,
                reset,
            );
            try writer.writeByte('\n');

            line_count += 1;
            first_line = false;
            start = end;
            if (prepared.wrap_on_words) {
                while (start < line_text.len and line_text[start] == ' ') : (start += 1) {}
            }
        }
    }

    return line_count;
}

fn prepareMarkdownLineAlloc(
    allocator: std.mem.Allocator,
    line: []const u8,
    state: *MarkdownRenderState,
) !MarkdownPreparedLine {
    const trimmed_leading = std.mem.trimLeft(u8, line, " \t");

    if (isCodeFenceLine(trimmed_leading)) {
        if (state.in_fenced_block) {
            state.in_fenced_block = false;
            return .{
                .text = try allocator.dupe(u8, "[/code]"),
                .kind = .fence,
                .supports_inline_code = false,
            };
        }

        state.in_fenced_block = true;
        const language = codeFenceLanguageToken(trimmed_leading);
        if (language.len == 0) {
            return .{
                .text = try allocator.dupe(u8, "[code]"),
                .kind = .fence,
                .supports_inline_code = false,
            };
        }
        return .{
            .text = try std.fmt.allocPrint(allocator, "[code: {s}]", .{language}),
            .kind = .fence,
            .supports_inline_code = false,
        };
    }

    if (state.in_fenced_block) {
        return .{
            .text = try allocator.dupe(u8, line),
            .kind = .code,
            .wrap_on_words = false,
            .supports_inline_code = false,
        };
    }

    const heading = parseMarkdownHeading(trimmed_leading);
    if (heading) |content| {
        return .{
            .text = try allocator.dupe(u8, content),
            .kind = .heading,
        };
    }

    if (parseMarkdownQuote(trimmed_leading)) |content| {
        const normalized = if (content.len == 0)
            try allocator.dupe(u8, "|")
        else
            try std.fmt.allocPrint(allocator, "| {s}", .{content});
        return .{
            .text = normalized,
            .kind = .quote,
        };
    }

    if (parseMarkdownList(trimmed_leading)) |content| {
        return .{
            .text = try allocator.dupe(u8, content),
            .kind = .list,
        };
    }

    return .{
        .text = try allocator.dupe(u8, line),
        .kind = .plain,
    };
}

fn writeMarkdownSegmentStyled(
    writer: *std.Io.Writer,
    segment: []const u8,
    prepared: MarkdownPreparedLine,
    inline_state: *InlineMarkdownState,
    palette: Palette,
    reset: []const u8,
) !void {
    if (segment.len == 0) return;

    const style = markdownLineStyle(prepared.kind, palette);
    if (!prepared.supports_inline_code) {
        try writeStyledSegment(writer, segment, style, reset);
        return;
    }

    var cursor: usize = 0;
    while (cursor < segment.len) {
        const next_tick_rel = std.mem.indexOfScalar(u8, segment[cursor..], '`');
        if (next_tick_rel == null) {
            const tail = segment[cursor..];
            if (tail.len > 0) {
                const run_style = if (inline_state.in_code) markdownInlineCodeStyle(palette) else style;
                try writeStyledSegment(writer, tail, run_style, reset);
            }
            break;
        }

        const tick_index = cursor + next_tick_rel.?;
        if (tick_index > cursor) {
            const chunk = segment[cursor..tick_index];
            const run_style = if (inline_state.in_code) markdownInlineCodeStyle(palette) else style;
            try writeStyledSegment(writer, chunk, run_style, reset);
        }

        inline_state.in_code = !inline_state.in_code;
        cursor = tick_index + 1;
    }
}

const SegmentStyle = struct {
    color: []const u8 = "",
    bold: bool = false,
    dim: bool = false,
};

fn markdownLineStyle(kind: MarkdownLineKind, palette: Palette) SegmentStyle {
    return switch (kind) {
        .plain => .{},
        .heading => .{ .color = palette.header, .bold = true },
        .quote => .{ .color = palette.dim, .dim = true },
        .list => .{ .color = palette.accent },
        .code => .{ .color = palette.accent },
        .fence => .{ .color = palette.dim, .dim = true },
    };
}

fn markdownInlineCodeStyle(palette: Palette) SegmentStyle {
    return .{ .color = palette.accent, .bold = true };
}

fn writeStyledSegment(
    writer: *std.Io.Writer,
    segment: []const u8,
    style: SegmentStyle,
    reset: []const u8,
) !void {
    if (segment.len == 0) return;

    const use_ansi = reset.len > 0;
    if (!use_ansi) {
        try writer.writeAll(segment);
        return;
    }

    if (style.bold) try writer.writeAll("\x1b[1m");
    if (style.dim) try writer.writeAll("\x1b[2m");
    if (style.color.len > 0) try writer.writeAll(style.color);
    try writer.writeAll(segment);
    try writer.writeAll(reset);
}

fn parseMarkdownHeading(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;

    var index: usize = 0;
    while (index < line.len and line[index] == '#') : (index += 1) {}
    if (index == 0 or index > 6) return null;
    if (index >= line.len or line[index] != ' ') return null;

    return std.mem.trimLeft(u8, line[index + 1 ..], " \t");
}

fn parseMarkdownQuote(line: []const u8) ?[]const u8 {
    if (line.len == 0 or line[0] != '>') return null;
    return std.mem.trimLeft(u8, line[1..], " \t");
}

fn parseMarkdownList(line: []const u8) ?[]const u8 {
    if (line.len < 2) return null;

    if ((line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
        return line;
    }

    var index: usize = 0;
    while (index < line.len and std.ascii.isDigit(line[index])) : (index += 1) {}
    if (index == 0 or index + 1 >= line.len) return null;
    if (line[index] != '.' or line[index + 1] != ' ') return null;
    return line;
}

fn writeWrappedPrefixedDiff(
    writer: *std.Io.Writer,
    text: []const u8,
    width: usize,
    first_prefix: []const u8,
    next_prefix: []const u8,
    prefix_color: []const u8,
    palette: Palette,
    reset: []const u8,
) !usize {
    var line_count: usize = 0;
    var first_line = true;
    var diff_state: DiffRenderState = .{};

    var paragraphs = std.mem.splitScalar(u8, text, '\n');
    while (paragraphs.next()) |paragraph| {
        const para = std.mem.trimRight(u8, paragraph, " ");
        const content_color = diffRenderColorForLine(&diff_state, para, palette);

        if (para.len == 0) {
            const prefix = if (first_line) first_prefix else next_prefix;
            try writer.print("{s}{s}{s}\n", .{ prefix_color, prefix, reset });
            first_line = false;
            line_count += 1;
            continue;
        }

        var start: usize = 0;
        while (start < para.len) {
            const prefix = if (first_line) first_prefix else next_prefix;
            const prefix_len = prefix.len;
            const wrap_width = @max(@as(usize, 1), width -| prefix_len);
            const max_end = @min(start + wrap_width, para.len);

            var end = max_end;
            if (max_end < para.len) {
                var cursor = max_end;
                while (cursor > start and para[cursor - 1] != ' ') : (cursor -= 1) {}
                if (cursor > start) end = cursor - 1;
            }
            if (end <= start) end = max_end;

            try writer.print("{s}{s}{s}", .{ prefix_color, prefix, reset });
            if (content_color.len > 0) try writer.writeAll(content_color);
            try writer.writeAll(std.mem.trimRight(u8, para[start..end], " "));
            if (content_color.len > 0) try writer.writeAll(reset);
            try writer.writeByte('\n');

            line_count += 1;
            first_line = false;
            start = end;
            while (start < para.len and para[start] == ' ') : (start += 1) {}
        }
    }

    return line_count;
}

fn formatTokenCount(allocator: std.mem.Allocator, raw_count: i64) ![]u8 {
    const count = @max(@as(i64, 0), raw_count);
    if (count >= 1_000_000) {
        const scaled = @as(f64, @floatFromInt(count)) / 1_000_000.0;
        const rounded = @round(scaled);
        if (@abs(scaled - rounded) < 0.05) {
            return std.fmt.allocPrint(allocator, "{d}M", .{@as(i64, @intFromFloat(rounded))});
        }
        return std.fmt.allocPrint(allocator, "{d:.1}M", .{scaled});
    }
    if (count >= 1_000) {
        const scaled = @as(f64, @floatFromInt(count)) / 1_000.0;
        const rounded = @round(scaled);
        if (@abs(scaled - rounded) < 0.05) {
            return std.fmt.allocPrint(allocator, "{d}k", .{@as(i64, @intFromFloat(rounded))});
        }
        return std.fmt.allocPrint(allocator, "{d:.1}k", .{scaled});
    }
    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

fn truncateLineAlloc(allocator: std.mem.Allocator, text: []const u8, max_width: usize) ![]u8 {
    if (text.len <= max_width) return allocator.dupe(u8, text);
    if (max_width <= 3) return allocator.dupe(u8, text[0..max_width]);

    const out_len = max_width;
    var out = try allocator.alloc(u8, out_len);
    @memcpy(out[0 .. out_len - 3], text[0 .. out_len - 3]);
    out[out_len - 3] = '.';
    out[out_len - 2] = '.';
    out[out_len - 1] = '.';
    return out;
}

fn buildInputView(allocator: std.mem.Allocator, before: []const u8, after: []const u8, max_width: usize) !InputView {
    var full_writer: std.Io.Writer.Allocating = .init(allocator);
    defer full_writer.deinit();
    try full_writer.writer.writeAll(before);
    try full_writer.writer.writeByte('|');
    try full_writer.writer.writeAll(after);
    const full = try full_writer.toOwnedSlice();
    defer allocator.free(full);

    const marker_view = blk: {
        if (full.len <= max_width) break :blk try allocator.dupe(u8, full);
        if (max_width <= 3) break :blk try allocator.dupe(u8, full[full.len - max_width ..]);

        const tail_len = max_width - 3;
        var out = try allocator.alloc(u8, max_width);
        out[0] = '.';
        out[1] = '.';
        out[2] = '.';
        @memcpy(out[3..], full[full.len - tail_len ..]);
        break :blk out;
    };
    defer allocator.free(marker_view);

    const marker_index = std.mem.indexOfScalar(u8, marker_view, '|') orelse marker_view.len;
    const has_marker = marker_index < marker_view.len;
    const out_len = marker_view.len - (if (has_marker) @as(usize, 1) else @as(usize, 0));
    var out = try allocator.alloc(u8, out_len);

    if (has_marker) {
        @memcpy(out[0..marker_index], marker_view[0..marker_index]);
        @memcpy(out[marker_index..], marker_view[marker_index + 1 ..]);
    } else {
        @memcpy(out, marker_view);
    }

    return .{
        .text = out,
        .cursor_col = @min(marker_index, out_len),
    };
}

const BuiltinCommandEntry = struct {
    name: []const u8,
    description: []const u8,
    insert_trailing_space: bool = true,
};

const QuickActionId = enum {
    new_chat,
    open_conversation_switch,
    open_model_picker,
    open_provider_command,
    compact_session,
    refresh_models_cache,
    refresh_file_index,
    toggle_ui_density,
    toggle_theme,
    show_help,
};

const QuickActionEntry = struct {
    id: QuickActionId,
    label: []const u8,
    description: []const u8,
    keywords: []const u8 = "",
};

const ProviderPickerEntry = struct {
    command_suffix: []const u8,
    description: []const u8,
};

const BUILTIN_COMMANDS = [_]BuiltinCommandEntry{
    .{ .name = "help", .description = "open command palette", .insert_trailing_space = false },
    .{ .name = "commands", .description = "open quick action palette", .insert_trailing_space = false },
    .{ .name = "provider", .description = "set provider (+ openai auth mode)" },
    .{ .name = "model", .description = "pick or set model id" },
    .{ .name = "models", .description = "list models cache / refresh" },
    .{ .name = "files", .description = "show file index / refresh" },
    .{ .name = "skills", .description = "list skill catalog / refresh / inspect" },
    .{ .name = "compact", .description = "compact conversation / auto [on|off]" },
    .{ .name = "new", .description = "create conversation" },
    .{ .name = "sessions", .description = "switch conversation session (picker or id)" },
    .{ .name = "title", .description = "rename conversation" },
    .{ .name = "theme", .description = "set theme (codex/plain/forest)" },
    .{ .name = "ui", .description = "set ui mode (compact/comfy)" },
    .{ .name = "paste-image", .description = "paste clipboard image into @path" },
    .{ .name = "quit", .description = "exit app", .insert_trailing_space = false },
    .{ .name = "q", .description = "exit app", .insert_trailing_space = false },
};

const QUICK_ACTIONS = [_]QuickActionEntry{
    .{ .id = .new_chat, .label = "New chat", .description = "create a new conversation", .keywords = "conversation create /new" },
    .{ .id = .open_conversation_switch, .label = "Switch session", .description = "open conversation sessions picker", .keywords = "conversation sessions /sessions /switch" },
    .{ .id = .open_model_picker, .label = "Switch model", .description = "open /model picker", .keywords = "model provider" },
    .{ .id = .open_provider_command, .label = "Switch provider", .description = "insert /provider command", .keywords = "provider" },
    .{ .id = .compact_session, .label = "Compact session", .description = "run /compact now", .keywords = "compact context summarize" },
    .{ .id = .refresh_models_cache, .label = "Refresh models cache", .description = "run /models refresh", .keywords = "models cache reload" },
    .{ .id = .refresh_file_index, .label = "Refresh file index", .description = "run /files refresh", .keywords = "files index rg" },
    .{ .id = .toggle_ui_density, .label = "Toggle UI density", .description = "switch compact/comfy UI", .keywords = "compact comfy ui" },
    .{ .id = .toggle_theme, .label = "Toggle theme", .description = "cycle codex/plain/forest", .keywords = "theme colors" },
    .{ .id = .show_help, .label = "Show help", .description = "open command palette", .keywords = "help commands palette" },
};

const PROVIDER_PICKER_OPENAI_AUTH_OPTIONS = [_]ProviderPickerEntry{
    .{ .command_suffix = "openai auto", .description = "openai provider + auto auth mode" },
    .{ .command_suffix = "openai api_key", .description = "openai provider + API key auth mode" },
    .{ .command_suffix = "openai codex", .description = "openai provider + codex subscription auth mode" },
};

fn parseSlashCommandPickerQuery(input: []const u8, cursor: usize) ?[]const u8 {
    if (input.len == 0 or input[0] != '/') return null;

    const first_space = std.mem.indexOfAny(u8, input, " \t\r\n");
    if (first_space) |space_index| {
        if (cursor > space_index) return null;
        return input[1..space_index];
    }

    return input[1..];
}

fn parseQuickActionPickerQuery(input: []const u8, cursor: usize) ?[]const u8 {
    if (input.len == 0 or input[0] != '>') return null;
    if (cursor == 0) return "";

    const query_cursor = @min(cursor, input.len);
    return std.mem.trimLeft(u8, input[1..query_cursor], " ");
}

fn parseConversationSwitchPickerQuery(input: []const u8, cursor: usize) ?[]const u8 {
    if (std.mem.startsWith(u8, input, "/sessions")) {
        if (input.len == 9) return "";
        if (input.len > 9 and input[9] == ' ') {
            const query_start: usize = 10;
            const query_cursor = @max(query_start, @min(cursor, input.len));
            return std.mem.trimLeft(u8, input[query_start..query_cursor], " ");
        }
        return null;
    }

    if (std.mem.startsWith(u8, input, "/switch")) {
        if (input.len == 7) return "";
        if (input.len > 7 and input[7] == ' ') {
            const query_start: usize = 8;
            const query_cursor = @max(query_start, @min(cursor, input.len));
            return std.mem.trimLeft(u8, input[query_start..query_cursor], " ");
        }
    }
    return null;
}

fn parseProviderPickerQuery(input: []const u8, cursor: usize) ?[]const u8 {
    if (!std.mem.startsWith(u8, input, "/provider")) return null;
    const command_len: usize = 9;
    if (cursor < command_len) return null;

    if (input.len == command_len) return "";
    if (input.len > command_len and input[command_len] == ' ') {
        const query_start: usize = command_len + 1;
        const query_cursor = @max(query_start, @min(cursor, input.len));
        return std.mem.trimLeft(u8, input[query_start..query_cursor], " ");
    }
    return null;
}

fn commandMatchesQuery(entry: BuiltinCommandEntry, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(entry.name, query) or containsAsciiIgnoreCase(entry.description, query);
}

fn quickActionMatchesQuery(entry: QuickActionEntry, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(entry.label, query) or
        containsAsciiIgnoreCase(entry.description, query) or
        containsAsciiIgnoreCase(entry.keywords, query);
}

fn conversationMatchesQuery(conversation: *const Conversation, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(conversation.id, query) or containsAsciiIgnoreCase(conversation.title, query);
}

fn providerPickerEntryMatches(entry: ProviderPickerEntry, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(entry.command_suffix, query) or
        containsAsciiIgnoreCase(entry.description, query);
}

const ConversationRelativeAge = struct {
    value: i64 = 0,
    unit: []const u8 = "s",
    just_now: bool = false,
};

fn conversationTimestampMs(conversation: *const Conversation) i64 {
    return @max(conversation.updated_ms, conversation.created_ms);
}

fn conversationRelativeAge(now_ms: i64, then_ms: i64) ConversationRelativeAge {
    const delta_ms = @max(@as(i64, 0), now_ms - then_ms);
    if (delta_ms < 5_000) return .{ .just_now = true };
    if (delta_ms < 60_000) return .{ .value = @divFloor(delta_ms, 1_000), .unit = "s" };
    if (delta_ms < 3_600_000) return .{ .value = @divFloor(delta_ms, 60_000), .unit = "m" };
    if (delta_ms < 86_400_000) return .{ .value = @divFloor(delta_ms, 3_600_000), .unit = "h" };
    return .{ .value = @divFloor(delta_ms, 86_400_000), .unit = "d" };
}

fn conversationAgeLabelAlloc(allocator: std.mem.Allocator, age: ConversationRelativeAge) ![]u8 {
    if (age.just_now) return allocator.dupe(u8, "now");
    return std.fmt.allocPrint(allocator, "{d}{s} ago", .{ age.value, age.unit });
}

fn sessionPickerTitleMaxWidth(width: usize, id_len: usize, age_label_len: usize) usize {
    const base_len = 7 + id_len + age_label_len;
    if (width <= base_len) return 0;
    const available = width - base_len;
    return @min(available, @as(usize, 56));
}

fn shouldIncludeConversationInSessionOrder(
    conversations: []const Conversation,
    index: usize,
    current_index: usize,
    include_blank_drafts: bool,
) bool {
    if (include_blank_drafts) return true;
    const conversation = &conversations[index];
    _ = current_index;
    return conversation.messages.items.len > 0;
}

fn countVisibleSessionConversations(
    conversations: []const Conversation,
    current_index: usize,
    include_blank_drafts: bool,
) usize {
    var count: usize = 0;
    for (conversations, 0..) |_, index| {
        if (shouldIncludeConversationInSessionOrder(conversations, index, current_index, include_blank_drafts)) {
            count += 1;
        }
    }
    return count;
}

fn conversationSortComesBefore(conversations: []const Conversation, lhs_index: usize, rhs_index: usize) bool {
    const lhs = &conversations[lhs_index];
    const rhs = &conversations[rhs_index];

    if (lhs.updated_ms != rhs.updated_ms) return lhs.updated_ms > rhs.updated_ms;
    if (lhs.created_ms != rhs.created_ms) return lhs.created_ms > rhs.created_ms;
    return lhs_index > rhs_index;
}

fn collectConversationSwitchMatchOrder(
    allocator: std.mem.Allocator,
    conversations: []const Conversation,
    current_index: usize,
    query: []const u8,
    include_blank_drafts: bool,
) !std.ArrayList(usize) {
    var ordered: std.ArrayList(usize) = .empty;
    errdefer ordered.deinit(allocator);

    for (conversations, 0..) |*conversation, index| {
        if (!shouldIncludeConversationInSessionOrder(conversations, index, current_index, include_blank_drafts)) continue;
        if (!conversationMatchesQuery(conversation, query)) continue;

        var insert_at = ordered.items.len;
        for (ordered.items, 0..) |existing_index, existing_position| {
            if (conversationSortComesBefore(conversations, index, existing_index)) {
                insert_at = existing_position;
                break;
            }
        }
        try ordered.insert(allocator, insert_at, index);
    }

    return ordered;
}

fn registerStreamInterruptByte(
    esc_count: *u8,
    last_esc_ms: *i64,
    key_byte: u8,
    now_ms: i64,
) bool {
    if (key_byte != 27) {
        esc_count.* = 0;
        last_esc_ms.* = 0;
        return false;
    }

    if (esc_count.* == 0 or (now_ms - last_esc_ms.*) > STREAM_INTERRUPT_ESC_WINDOW_MS) {
        esc_count.* = 1;
        last_esc_ms.* = now_ms;
        return false;
    }

    esc_count.* = 0;
    last_esc_ms.* = 0;
    return true;
}

const AssistantToolCall = union(enum) {
    read: []const u8,
    list_dir: []const u8,
    read_file: []const u8,
    grep_files: []const u8,
    project_search: []const u8,
    apply_patch: []const u8,
    exec_command: []const u8,
    write_stdin: []const u8,
    web_search: []const u8,
    view_image: []const u8,
    skill: []const u8,
};

fn parseAssistantToolCall(text: []const u8) ?AssistantToolCall {
    if (parseListDirToolPayload(text)) |payload| {
        return .{ .list_dir = payload };
    }
    if (parseReadFileToolPayload(text)) |payload| {
        return .{ .read_file = payload };
    }
    if (parseGrepFilesToolPayload(text)) |payload| {
        return .{ .grep_files = payload };
    }
    if (parseProjectSearchToolPayload(text)) |payload| {
        return .{ .project_search = payload };
    }
    if (parseExecCommandToolPayload(text)) |payload| {
        return .{ .exec_command = payload };
    }
    if (parseWriteStdinToolPayload(text)) |payload| {
        return .{ .write_stdin = payload };
    }
    if (parseWebSearchToolPayload(text)) |payload| {
        return .{ .web_search = payload };
    }
    if (parseViewImageToolPayload(text)) |payload| {
        return .{ .view_image = payload };
    }
    if (parseSkillToolPayload(text)) |payload| {
        return .{ .skill = payload };
    }
    if (parseReadToolCommand(text)) |command| {
        return .{ .read = command };
    }
    if (parseApplyPatchToolPayload(text)) |patch_text| {
        return .{ .apply_patch = patch_text };
    }
    return null;
}

fn parseListDirToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<LIST_DIR>")) {
        const rest = trimmed["<LIST_DIR>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</LIST_DIR>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```list_dir")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseReadFileToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<READ_FILE>")) {
        const rest = trimmed["<READ_FILE>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</READ_FILE>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```read_file")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseGrepFilesToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<GREP_FILES>")) {
        const rest = trimmed["<GREP_FILES>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</GREP_FILES>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```grep_files")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseProjectSearchToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<PROJECT_SEARCH>")) {
        const rest = trimmed["<PROJECT_SEARCH>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</PROJECT_SEARCH>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```project_search")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseReadToolCommand(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<READ>")) {
        const rest = trimmed["<READ>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</READ>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "READ:")) {
        return std.mem.trimLeft(u8, trimmed["READ:".len..], " \t");
    }

    if (std.mem.startsWith(u8, trimmed, "READ ")) {
        return std.mem.trimLeft(u8, trimmed["READ".len..], " \t");
    }

    if (std.mem.startsWith(u8, trimmed, "```read")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    // Accept codex-style inline marker output:
    // [tool] READ git status --short
    if (std.mem.startsWith(u8, trimmed, "[tool]")) {
        const after_marker = std.mem.trimLeft(u8, trimmed["[tool]".len..], " \t");
        if (after_marker.len >= 4 and std.mem.startsWith(u8, after_marker, "READ")) {
            const command = std.mem.trimLeft(u8, after_marker["READ".len..], " \t:");
            if (command.len > 0) return command;
        }
    }

    return null;
}

fn parseExecCommandToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<EXEC_COMMAND>")) {
        const rest = trimmed["<EXEC_COMMAND>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</EXEC_COMMAND>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```exec_command")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseWriteStdinToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<WRITE_STDIN>")) {
        const rest = trimmed["<WRITE_STDIN>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</WRITE_STDIN>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```write_stdin")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseWebSearchToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<WEB_SEARCH>")) {
        const rest = trimmed["<WEB_SEARCH>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</WEB_SEARCH>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```web_search")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseViewImageToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<VIEW_IMAGE>")) {
        const rest = trimmed["<VIEW_IMAGE>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</VIEW_IMAGE>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```view_image")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    return null;
}

fn parseSkillToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<SKILL>")) {
        const rest = trimmed["<SKILL>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</SKILL>") orelse return null;
        return std.mem.trim(u8, rest[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "```skill")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        return std.mem.trim(u8, body[0..close_index], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "[tool]")) {
        const after_marker = std.mem.trimLeft(u8, trimmed["[tool]".len..], " \t");
        if (after_marker.len >= 5 and std.mem.startsWith(u8, after_marker, "SKILL")) {
            const name = std.mem.trimLeft(u8, after_marker["SKILL".len..], " \t:");
            if (name.len > 0) return name;
        }
    }

    return null;
}

fn parseApplyPatchToolPayload(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.startsWith(u8, trimmed, "<APPLY_PATCH>")) {
        const rest = trimmed["<APPLY_PATCH>".len..];
        const close_index = std.mem.indexOf(u8, rest, "</APPLY_PATCH>") orelse return null;
        const payload = std.mem.trim(u8, rest[0..close_index], " \t\r\n");
        if (payload.len == 0) return null;
        return payload;
    }

    if (std.mem.startsWith(u8, trimmed, "```apply_patch")) {
        const first_newline = std.mem.indexOfScalar(u8, trimmed, '\n') orelse return null;
        const body = trimmed[first_newline + 1 ..];
        const close_index = std.mem.indexOf(u8, body, "```") orelse return null;
        const payload = std.mem.trim(u8, body[0..close_index], " \t\r\n");
        if (payload.len == 0) return null;
        return payload;
    }

    return extractCodexPatchPayload(trimmed);
}

fn parseExecCommandInput(allocator: std.mem.Allocator, payload: []const u8) !ExecCommandInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{
            .cmd = try allocator.dupe(u8, trimmed),
            .yield_ms = COMMAND_TOOL_DEFAULT_YIELD_MS,
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const cmd_value = object.get("cmd") orelse object.get("command") orelse return error.InvalidToolPayload;
    const cmd_text = switch (cmd_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const yield_ms = sanitizeCommandYieldMs(
        jsonFieldU32(object, "yield_ms") orelse
            jsonFieldU32(object, "yield_time_ms") orelse
            COMMAND_TOOL_DEFAULT_YIELD_MS,
    );

    return .{
        .cmd = try allocator.dupe(u8, std.mem.trim(u8, cmd_text, " \t\r\n")),
        .yield_ms = yield_ms,
    };
}

fn parseWriteStdinInput(allocator: std.mem.Allocator, payload: []const u8) !WriteStdinInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return error.InvalidToolPayload;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const session_value = object.get("session_id") orelse object.get("session") orelse return error.InvalidToolPayload;
    const session_id = switch (session_value) {
        .integer => |number| if (number > 0 and number <= std.math.maxInt(u32)) @as(u32, @intCast(number)) else return error.InvalidToolPayload,
        .number_string => |number| std.fmt.parseInt(u32, number, 10) catch return error.InvalidToolPayload,
        else => return error.InvalidToolPayload,
    };

    const chars_text = if (object.get("chars")) |chars_value|
        switch (chars_value) {
            .string => |text| text,
            else => return error.InvalidToolPayload,
        }
    else
        "";

    const yield_ms = sanitizeCommandYieldMs(
        jsonFieldU32(object, "yield_ms") orelse
            jsonFieldU32(object, "yield_time_ms") orelse
            COMMAND_TOOL_DEFAULT_YIELD_MS,
    );

    return .{
        .session_id = session_id,
        .chars = try allocator.dupe(u8, chars_text),
        .yield_ms = yield_ms,
    };
}

fn parseWebSearchInput(allocator: std.mem.Allocator, payload: []const u8) !WebSearchInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{
            .query = try allocator.dupe(u8, trimmed),
            .limit = WEB_SEARCH_DEFAULT_RESULTS,
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const query_value = object.get("query") orelse object.get("q") orelse return error.InvalidToolPayload;
    const query = switch (query_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const limit = sanitizeWebSearchLimit(
        jsonFieldU32(object, "limit") orelse
            jsonFieldU32(object, "count") orelse
            jsonFieldU32(object, "max_results") orelse
            WEB_SEARCH_DEFAULT_RESULTS,
    );

    const engine: WebSearchEngine = blk: {
        const engine_value = object.get("engine") orelse object.get("provider") orelse break :blk .duckduckgo;
        const engine_name = switch (engine_value) {
            .string => |text| text,
            else => return error.InvalidToolPayload,
        };
        break :blk parseWebSearchEngineName(engine_name) orelse return error.InvalidToolPayload;
    };

    return .{
        .query = try allocator.dupe(u8, std.mem.trim(u8, query, " \t\r\n")),
        .limit = limit,
        .engine = engine,
    };
}

fn parseViewImageInput(allocator: std.mem.Allocator, payload: []const u8) !ViewImageInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{
            .path = try allocator.dupe(u8, trimMatchingOuterQuotes(trimmed)),
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("file") orelse return error.InvalidToolPayload;
    const path_text = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    return .{
        .path = try allocator.dupe(u8, trimMatchingOuterQuotes(std.mem.trim(u8, path_text, " \t\r\n"))),
    };
}

fn parseListDirInput(allocator: std.mem.Allocator, payload: []const u8) !ListDirInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{
            .path = try allocator.dupe(u8, trimmed),
            .recursive = false,
            .max_entries = LIST_DIR_DEFAULT_MAX_ENTRIES,
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const path = if (object.get("path")) |value| switch (value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    } else ".";

    return .{
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .recursive = jsonFieldBool(object, "recursive") orelse false,
        .max_entries = sanitizeListDirMaxEntries(
            jsonFieldU32(object, "max_entries") orelse
                jsonFieldU32(object, "limit") orelse
                LIST_DIR_DEFAULT_MAX_ENTRIES,
        ),
    };
}

fn parseReadFileInput(allocator: std.mem.Allocator, payload: []const u8) !ReadFileInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{
            .path = try allocator.dupe(u8, trimmed),
            .max_bytes = READ_FILE_DEFAULT_MAX_BYTES,
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const path_value = object.get("path") orelse object.get("file") orelse return error.InvalidToolPayload;
    const path = switch (path_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const max_bytes = sanitizeReadFileMaxBytes(
        jsonFieldU32(object, "max_bytes") orelse
            jsonFieldU32(object, "limit") orelse
            READ_FILE_DEFAULT_MAX_BYTES,
    );

    return .{
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .max_bytes = max_bytes,
    };
}

fn parseGrepFilesInput(allocator: std.mem.Allocator, payload: []const u8) !GrepFilesInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{
            .query = try allocator.dupe(u8, trimmed),
            .path = try allocator.dupe(u8, "."),
            .glob = null,
            .max_matches = GREP_FILES_DEFAULT_MAX_MATCHES,
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const query_value = object.get("query") orelse object.get("q") orelse object.get("pattern") orelse return error.InvalidToolPayload;
    const query = switch (query_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const path = if (object.get("path")) |value| switch (value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    } else ".";

    const glob = if (object.get("glob")) |value| switch (value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    } else null;

    return .{
        .query = try allocator.dupe(u8, std.mem.trim(u8, query, " \t\r\n")),
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .glob = if (glob) |g| try allocator.dupe(u8, std.mem.trim(u8, g, " \t\r\n")) else null,
        .max_matches = sanitizeGrepMatches(
            jsonFieldU32(object, "max_matches") orelse
                jsonFieldU32(object, "limit") orelse
                GREP_FILES_DEFAULT_MAX_MATCHES,
        ),
    };
}

fn parseProjectSearchInput(allocator: std.mem.Allocator, payload: []const u8) !ProjectSearchInput {
    const trimmed = std.mem.trim(u8, payload, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidToolPayload;

    if (trimmed[0] != '{') {
        return .{
            .query = try allocator.dupe(u8, trimmed),
            .path = try allocator.dupe(u8, "."),
            .max_files = PROJECT_SEARCH_DEFAULT_MAX_FILES,
            .max_matches = PROJECT_SEARCH_DEFAULT_MAX_MATCHES,
        };
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidToolPayload,
    };

    const query_value = object.get("query") orelse object.get("q") orelse return error.InvalidToolPayload;
    const query = switch (query_value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    };

    const path = if (object.get("path")) |value| switch (value) {
        .string => |text| text,
        else => return error.InvalidToolPayload,
    } else ".";

    return .{
        .query = try allocator.dupe(u8, std.mem.trim(u8, query, " \t\r\n")),
        .path = try allocator.dupe(u8, std.mem.trim(u8, path, " \t\r\n")),
        .max_files = sanitizeProjectSearchMaxFiles(
            jsonFieldU32(object, "max_files") orelse
                jsonFieldU32(object, "limit") orelse
                PROJECT_SEARCH_DEFAULT_MAX_FILES,
        ),
        .max_matches = sanitizeProjectSearchMatches(
            jsonFieldU32(object, "max_matches") orelse
                jsonFieldU32(object, "max_hits") orelse
                PROJECT_SEARCH_DEFAULT_MAX_MATCHES,
        ),
    };
}

fn sanitizeListDirMaxEntries(limit: u32) u16 {
    if (limit == 0) return LIST_DIR_DEFAULT_MAX_ENTRIES;
    return @as(u16, @intCast(@min(limit, LIST_DIR_MAX_ENTRIES)));
}

fn sanitizeReadFileMaxBytes(limit: u32) u32 {
    if (limit == 0) return READ_FILE_DEFAULT_MAX_BYTES;
    return @min(limit, READ_FILE_MAX_BYTES);
}

fn sanitizeGrepMatches(limit: u32) u16 {
    if (limit == 0) return GREP_FILES_DEFAULT_MAX_MATCHES;
    return @as(u16, @intCast(@min(limit, GREP_FILES_MAX_MATCHES)));
}

fn sanitizeProjectSearchMaxFiles(limit: u32) u8 {
    if (limit == 0) return PROJECT_SEARCH_DEFAULT_MAX_FILES;
    return @as(u8, @intCast(@min(limit, PROJECT_SEARCH_MAX_FILES)));
}

fn sanitizeProjectSearchMatches(limit: u32) u16 {
    if (limit == 0) return PROJECT_SEARCH_DEFAULT_MAX_MATCHES;
    return @as(u16, @intCast(@min(limit, PROJECT_SEARCH_MAX_MATCHES)));
}

fn sanitizeWebSearchLimit(limit: u32) u8 {
    if (limit == 0) return WEB_SEARCH_DEFAULT_RESULTS;
    const clamped = @min(limit, WEB_SEARCH_MAX_RESULTS);
    return @as(u8, @intCast(clamped));
}

fn parseWebSearchEngineName(input: []const u8) ?WebSearchEngine {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "duckduckgo") or std.ascii.eqlIgnoreCase(trimmed, "ddg")) {
        return .duckduckgo;
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "exa")) {
        return .exa;
    }
    return null;
}

fn webSearchEngineLabel(engine: WebSearchEngine) []const u8 {
    return switch (engine) {
        .duckduckgo => "duckduckgo",
        .exa => "exa",
    };
}

fn parseDuckDuckGoHtmlResults(
    allocator: std.mem.Allocator,
    html: []const u8,
    limit: u8,
) ![]WebSearchResultItem {
    var results: std.ArrayList(WebSearchResultItem) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit(allocator);
        results.deinit(allocator);
    }

    var cursor: usize = 0;
    while (results.items.len < @as(usize, limit)) {
        const marker = std.mem.indexOfPos(u8, html, cursor, "result__a") orelse break;
        const tag_start = std.mem.lastIndexOfScalar(u8, html[0..marker], '<') orelse {
            cursor = marker + "result__a".len;
            continue;
        };
        const tag_end = std.mem.indexOfScalarPos(u8, html, marker, '>') orelse break;
        if (tag_start + 2 > tag_end or html[tag_start + 1] != 'a') {
            cursor = marker + "result__a".len;
            continue;
        }

        const close_anchor = std.mem.indexOfPos(u8, html, tag_end + 1, "</a>") orelse break;
        const tag = html[tag_start .. tag_end + 1];
        const href_raw = extractAnchorHref(tag) orelse {
            cursor = close_anchor + "</a>".len;
            continue;
        };

        const title_raw = html[tag_end + 1 .. close_anchor];
        const title = try stripHtmlTagsAndDecodeAlloc(allocator, title_raw);
        errdefer allocator.free(title);
        if (title.len == 0) {
            allocator.free(title);
            cursor = close_anchor + "</a>".len;
            continue;
        }

        const href_decoded = try decodeHtmlEntitiesAlloc(allocator, href_raw);
        defer allocator.free(href_decoded);
        const normalized_url = try normalizeSearchResultUrlAlloc(allocator, href_decoded);

        try results.append(allocator, .{
            .title = title,
            .url = normalized_url,
        });

        cursor = close_anchor + "</a>".len;
    }

    return results.toOwnedSlice(allocator);
}

fn parseExaJsonResults(
    allocator: std.mem.Allocator,
    payload: []const u8,
    limit: u8,
) ![]WebSearchResultItem {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidWebSearchResponse,
    };

    const results_value = root.get("results") orelse return error.InvalidWebSearchResponse;
    const results_array = switch (results_value) {
        .array => |array| array,
        else => return error.InvalidWebSearchResponse,
    };

    var out: std.ArrayList(WebSearchResultItem) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (results_array.items) |entry| {
        if (out.items.len >= @as(usize, limit)) break;
        const entry_object = switch (entry) {
            .object => |object| object,
            else => continue,
        };

        const url = if (entry_object.get("url")) |value| switch (value) {
            .string => |text| std.mem.trim(u8, text, " \t\r\n"),
            else => "",
        } else "";
        if (url.len == 0) continue;

        const title_raw = if (entry_object.get("title")) |value| switch (value) {
            .string => |text| std.mem.trim(u8, text, " \t\r\n"),
            else => "",
        } else "";
        const title = if (title_raw.len == 0) url else title_raw;

        try out.append(allocator, .{
            .title = try allocator.dupe(u8, title),
            .url = try allocator.dupe(u8, url),
        });
    }

    return out.toOwnedSlice(allocator);
}

fn extractAnchorHref(anchor_tag: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, anchor_tag, "href=\"")) |href_start| {
        const start = href_start + "href=\"".len;
        const end = std.mem.indexOfScalarPos(u8, anchor_tag, start, '"') orelse return null;
        return anchor_tag[start..end];
    }
    if (std.mem.indexOf(u8, anchor_tag, "href='")) |href_start| {
        const start = href_start + "href='".len;
        const end = std.mem.indexOfScalarPos(u8, anchor_tag, start, '\'') orelse return null;
        return anchor_tag[start..end];
    }
    return null;
}

fn stripHtmlTagsAndDecodeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var stripped_writer: std.Io.Writer.Allocating = .init(allocator);
    defer stripped_writer.deinit();

    var in_tag = false;
    for (text) |byte| {
        if (byte == '<') {
            in_tag = true;
            continue;
        }
        if (byte == '>') {
            in_tag = false;
            continue;
        }
        if (!in_tag) try stripped_writer.writer.writeByte(byte);
    }

    const stripped = try stripped_writer.toOwnedSlice();
    defer allocator.free(stripped);
    return decodeHtmlEntitiesAlloc(allocator, std.mem.trim(u8, stripped, " \t\r\n"));
}

fn decodeHtmlEntitiesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            const tail = text[i..];
            if (std.mem.startsWith(u8, tail, "&amp;")) {
                try out.writer.writeByte('&');
                i += "&amp;".len;
                continue;
            }
            if (std.mem.startsWith(u8, tail, "&quot;")) {
                try out.writer.writeByte('"');
                i += "&quot;".len;
                continue;
            }
            if (std.mem.startsWith(u8, tail, "&#39;")) {
                try out.writer.writeByte('\'');
                i += "&#39;".len;
                continue;
            }
            if (std.mem.startsWith(u8, tail, "&lt;")) {
                try out.writer.writeByte('<');
                i += "&lt;".len;
                continue;
            }
            if (std.mem.startsWith(u8, tail, "&gt;")) {
                try out.writer.writeByte('>');
                i += "&gt;".len;
                continue;
            }
        }

        try out.writer.writeByte(text[i]);
        i += 1;
    }

    return out.toOwnedSlice();
}

fn normalizeSearchResultUrlAlloc(allocator: std.mem.Allocator, href: []const u8) ![]u8 {
    if (try decodeDuckDuckGoRedirectUrlAlloc(allocator, href)) |decoded_target| {
        return decoded_target;
    }

    if (std.mem.startsWith(u8, href, "//")) {
        return std.fmt.allocPrint(allocator, "https:{s}", .{href});
    }

    return allocator.dupe(u8, href);
}

fn decodeDuckDuckGoRedirectUrlAlloc(allocator: std.mem.Allocator, href: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, href, "duckduckgo.com/l/?") == null) return null;

    const param_index = std.mem.indexOf(u8, href, "uddg=") orelse return null;
    const value_start = param_index + "uddg=".len;
    const remaining = href[value_start..];
    const value_end = std.mem.indexOfScalar(u8, remaining, '&') orelse remaining.len;
    const encoded_target = remaining[0..value_end];

    const decoded_buffer = try allocator.dupe(u8, encoded_target);
    defer allocator.free(decoded_buffer);
    const decoded = std.Uri.percentDecodeInPlace(decoded_buffer);
    return @as(?[]u8, try allocator.dupe(u8, decoded));
}

fn sanitizeCommandYieldMs(input_ms: u32) u32 {
    if (input_ms == 0) return 1;
    return @min(input_ms, COMMAND_TOOL_MAX_YIELD_MS);
}

fn jsonFieldU32(object: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @as(u32, @intCast(number)) else null,
        .number_string => |number| std.fmt.parseInt(u32, number, 10) catch null,
        .float => |number| if (number >= 0 and number <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) @as(u32, @intFromFloat(number)) else null,
        else => null,
    };
}

fn jsonFieldBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        .string => |text| blk: {
            if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1")) break :blk true;
            if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0")) break :blk false;
            break :blk null;
        },
        else => null,
    };
}

fn extractCodexPatchPayload(text: []const u8) ?[]const u8 {
    const begin_index = std.mem.indexOf(u8, text, "*** Begin Patch") orelse return null;
    const rest = text[begin_index..];
    const end_index = std.mem.indexOf(u8, rest, "*** End Patch") orelse return null;
    const end = begin_index + end_index + "*** End Patch".len;
    return std.mem.trim(u8, text[begin_index..end], " \t\r\n");
}

fn isValidApplyPatchPayload(patch_text: []const u8) bool {
    if (!std.mem.startsWith(u8, patch_text, "*** Begin Patch")) return false;
    return std.mem.indexOf(u8, patch_text, "*** End Patch") != null;
}

fn buildApplyPatchPreview(
    allocator: std.mem.Allocator,
    patch_text: []const u8,
    max_lines: usize,
) !ApplyPatchPreview {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var included_lines: usize = 0;
    var matched_lines: usize = 0;
    var lines = std.mem.splitScalar(u8, patch_text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (!isDiffPreviewLine(line)) continue;

        matched_lines += 1;
        if (included_lines >= max_lines) continue;

        included_lines += 1;
        try writer.writer.writeAll(line);
        try writer.writer.writeByte('\n');
    }

    return .{
        .text = try writer.toOwnedSlice(),
        .included_lines = included_lines,
        .omitted_lines = matched_lines - included_lines,
    };
}

fn isDiffPreviewLine(line: []const u8) bool {
    if (line.len == 0) return false;
    if (std.mem.startsWith(u8, line, "*** Begin Patch")) return true;
    if (std.mem.startsWith(u8, line, "*** End Patch")) return true;
    if (std.mem.startsWith(u8, line, "*** Add File:")) return true;
    if (std.mem.startsWith(u8, line, "*** Update File:")) return true;
    if (std.mem.startsWith(u8, line, "*** Delete File:")) return true;
    if (std.mem.startsWith(u8, line, "*** Move to:")) return true;
    if (std.mem.startsWith(u8, line, "@@")) return true;
    if (std.mem.startsWith(u8, line, "+")) return true;
    if (std.mem.startsWith(u8, line, "-")) return true;
    return false;
}

const AtTokenRange = struct {
    start: usize,
    end: usize,
    query: []const u8,
};

const RewriteResult = struct {
    text: []u8,
    cursor: usize,
};

fn currentAtTokenRange(input: []const u8, cursor: usize) ?AtTokenRange {
    const safe_cursor = @min(cursor, input.len);
    const before = input[0..safe_cursor];
    const after = input[safe_cursor..];

    const start = blk: {
        var i = before.len;
        while (i > 0) : (i -= 1) {
            if (std.ascii.isWhitespace(before[i - 1])) break;
        }
        break :blk i;
    };

    const end = blk: {
        var i: usize = 0;
        while (i < after.len and !std.ascii.isWhitespace(after[i])) : (i += 1) {}
        break :blk safe_cursor + i;
    };

    if (start >= end) return null;
    const token = input[start..end];
    if (token[0] != '@') return null;

    var query = token[1..];
    if (query.len > 0 and (query[0] == '"' or query[0] == '\'')) {
        query = query[1..];
    }

    return .{
        .start = start,
        .end = end,
        .query = query,
    };
}

fn currentAtTokenQuery(input: []const u8, cursor: usize) ?[]const u8 {
    const token = currentAtTokenRange(input, cursor) orelse return null;
    return token.query;
}

fn filePathMatchesQuery(path: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(path, query);
}

fn rewriteInputWithSelectedAtPath(
    allocator: std.mem.Allocator,
    input: []const u8,
    cursor: usize,
    path: []const u8,
) !RewriteResult {
    const token = currentAtTokenRange(input, cursor) orelse return error.MissingAtToken;

    const inserted_token = try atPathTokenForInsert(allocator, path);
    defer allocator.free(inserted_token);

    const suffix = std.mem.trimLeft(u8, input[token.end..], " \t");
    const new_len = token.start + inserted_token.len + 1 + suffix.len;
    var out = try allocator.alloc(u8, new_len);

    @memcpy(out[0..token.start], input[0..token.start]);
    @memcpy(out[token.start .. token.start + inserted_token.len], inserted_token);
    out[token.start + inserted_token.len] = ' ';
    @memcpy(out[token.start + inserted_token.len + 1 ..], suffix);

    return .{
        .text = out,
        .cursor = token.start + inserted_token.len + 1,
    };
}

fn insertAtPathTokenAtCursor(
    allocator: std.mem.Allocator,
    input: []const u8,
    cursor: usize,
    path: []const u8,
) !RewriteResult {
    const safe_cursor = @min(cursor, input.len);
    const inserted_token = try atPathTokenForInsert(allocator, path);
    defer allocator.free(inserted_token);

    const needs_leading_space = safe_cursor > 0 and !std.ascii.isWhitespace(input[safe_cursor - 1]);
    const needs_trailing_space = safe_cursor < input.len and !std.ascii.isWhitespace(input[safe_cursor]);
    const extra: usize = (if (needs_leading_space) @as(usize, 1) else 0) + (if (needs_trailing_space) @as(usize, 1) else 0);
    const new_len = input.len + inserted_token.len + extra;
    var out = try allocator.alloc(u8, new_len);

    var write_index: usize = 0;
    @memcpy(out[write_index .. write_index + safe_cursor], input[0..safe_cursor]);
    write_index += safe_cursor;

    if (needs_leading_space) {
        out[write_index] = ' ';
        write_index += 1;
    }

    @memcpy(out[write_index .. write_index + inserted_token.len], inserted_token);
    write_index += inserted_token.len;

    if (needs_trailing_space) {
        out[write_index] = ' ';
        write_index += 1;
    }

    @memcpy(out[write_index .. write_index + (input.len - safe_cursor)], input[safe_cursor..]);
    write_index += input.len - safe_cursor;
    std.debug.assert(write_index == new_len);

    return .{
        .text = out,
        .cursor = safe_cursor + (if (needs_leading_space) @as(usize, 1) else 0) + inserted_token.len + (if (needs_trailing_space) @as(usize, 1) else 0),
    };
}

fn atPathTokenForInsert(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const quoted = blk: {
        if (!containsWhitespace(path)) break :blk false;
        if (std.mem.indexOfScalar(u8, path, '"') == null) break :blk true;
        break :blk false;
    };
    return if (quoted)
        std.fmt.allocPrint(allocator, "@\"{s}\"", .{path})
    else
        std.fmt.allocPrint(allocator, "@{s}", .{path});
}

fn containsWhitespace(text: []const u8) bool {
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch)) return true;
    }
    return false;
}

fn findGitTopLevelAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .cwd = ".",
        .max_output_bytes = 16 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, trimmed));
}

fn pathHasRootPrefix(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    const next = path[root.len];
    return next == '/' or next == '\\';
}

fn formatInjectedPathForSummaryAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    cwd: ?[]const u8,
    repo_root: ?[]const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, path);

    var absolute_path_owned: ?[]u8 = null;
    defer if (absolute_path_owned) |owned| allocator.free(owned);

    const absolute_path = blk: {
        if (std.fs.path.isAbsolute(trimmed)) break :blk trimmed;
        if (cwd) |cwd_path| {
            absolute_path_owned = try std.fs.path.join(allocator, &.{ cwd_path, trimmed });
            break :blk absolute_path_owned.?;
        }
        break :blk trimmed;
    };

    if (repo_root) |root| {
        if (pathHasRootPrefix(absolute_path, root)) {
            const suffix = std.mem.trimLeft(u8, absolute_path[root.len..], "/\\");
            if (suffix.len == 0) return allocator.dupe(u8, ".");
            return allocator.dupe(u8, suffix);
        }
    }

    return allocator.dupe(u8, trimmed);
}

const FileInjectResult = struct {
    payload: ?[]u8 = null,
    referenced_count: usize = 0,
    included_count: usize = 0,
    skipped_count: usize = 0,
};

const SkillInjectResult = struct {
    payload: ?[]u8 = null,
    referenced_count: usize = 0,
    included_count: usize = 0,
    skipped_count: usize = 0,
};

fn buildFileInjectionPayload(allocator: std.mem.Allocator, prompt: []const u8) !FileInjectResult {
    var references = try collectAtFileReferences(allocator, prompt);
    defer {
        for (references.items) |entry| allocator.free(entry);
        references.deinit(allocator);
    }

    if (references.items.len == 0) return .{};

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    var included_paths: std.ArrayList([]const u8) = .empty;
    defer included_paths.deinit(allocator);
    const cwd = std.process.getCwdAlloc(allocator) catch null;
    defer if (cwd) |path| allocator.free(path);
    const repo_root = findGitTopLevelAlloc(allocator) catch null;
    defer if (repo_root) |path| allocator.free(path);

    var included_count: usize = 0;
    var skipped_count: usize = 0;

    for (references.items, 0..) |reference, index| {
        if (included_count >= FILE_INJECT_MAX_FILES) {
            skipped_count += references.items.len - index;
            break;
        }

        const path = trimMatchingOuterQuotes(reference);
        if (path.len == 0) {
            skipped_count += 1;
            continue;
        }

        const image_info = inspectImageFile(allocator, path, false) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => null,
        };
        if (image_info) |info| {
            included_count += 1;
            try included_paths.append(allocator, path);
            try body_writer.writer.print(
                "<image path=\"{s}\" mime=\"{s}\" format=\"{s}\" bytes=\"{d}\"",
                .{ path, info.mime, info.format, info.bytes },
            );
            if (info.width != null and info.height != null) {
                try body_writer.writer.print(" width=\"{d}\" height=\"{d}\"", .{ info.width.?, info.height.? });
            }
            try body_writer.writer.writeAll(" />\n");
            continue;
        }

        const file_content = readFileForInjection(allocator, path) catch {
            skipped_count += 1;
            continue;
        };
        defer allocator.free(file_content);

        if (looksBinary(file_content)) {
            skipped_count += 1;
            continue;
        }

        included_count += 1;
        try included_paths.append(allocator, path);
        try body_writer.writer.print("<file path=\"{s}\">\n", .{path});
        try body_writer.writer.writeAll(file_content);
        if (file_content.len == 0 or file_content[file_content.len - 1] != '\n') {
            try body_writer.writer.writeByte('\n');
        }
        try body_writer.writer.writeAll("</file>\n");
    }

    if (included_count == 0) {
        return .{
            .referenced_count = references.items.len,
            .included_count = 0,
            .skipped_count = skipped_count,
        };
    }

    const body = try body_writer.toOwnedSlice();
    defer allocator.free(body);

    var payload_writer: std.Io.Writer.Allocating = .init(allocator);
    defer payload_writer.deinit();

    try payload_writer.writer.print(
        "{s} included:{d} referenced:{d} skipped:{d}",
        .{ FILE_INJECT_HEADER, included_count, references.items.len, skipped_count },
    );
    if (included_paths.items.len > 0) {
        try payload_writer.writer.writeAll(" read: ");
        const shown = @min(included_paths.items.len, @as(usize, 3));
        for (included_paths.items[0..shown], 0..) |path, idx| {
            if (idx > 0) try payload_writer.writer.writeAll(", ");
            const display_name = try formatInjectedPathForSummaryAlloc(allocator, path, cwd, repo_root);
            defer allocator.free(display_name);
            try payload_writer.writer.writeAll(display_name);
        }
        if (included_paths.items.len > shown) {
            try payload_writer.writer.print(" (+{d} more)", .{included_paths.items.len - shown});
        }
    }
    try payload_writer.writer.writeByte('\n');
    try payload_writer.writer.writeAll(
        "The user referenced these files with @path. Treat this as project context. For <image .../> entries use <VIEW_IMAGE> to inspect metadata.\n",
    );
    try payload_writer.writer.writeAll(body);

    return .{
        .payload = try payload_writer.toOwnedSlice(),
        .referenced_count = references.items.len,
        .included_count = included_count,
        .skipped_count = skipped_count,
    };
}

fn collectAtFileReferences(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]u8) {
    var refs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (refs.items) |entry| allocator.free(entry);
        refs.deinit(allocator);
    }

    var dedupe: std.StringHashMapUnmanaged(void) = .empty;
    defer dedupe.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '@') continue;
        if (index > 0 and !std.ascii.isWhitespace(text[index - 1])) continue;

        var normalized: []const u8 = undefined;
        if (index + 1 < text.len and (text[index + 1] == '"' or text[index + 1] == '\'')) {
            const quote = text[index + 1];
            var end = index + 2;
            while (end < text.len and text[end] != quote) : (end += 1) {}
            if (end >= text.len) continue;

            normalized = text[index + 2 .. end];
            index = end;
        } else {
            var end = index + 1;
            while (end < text.len and !std.ascii.isWhitespace(text[end])) : (end += 1) {}
            if (end <= index + 1) continue;

            const token = text[index + 1 .. end];
            normalized = trimMatchingOuterQuotes(token);
            index = end - 1;
        }

        if (normalized.len == 0) continue;

        if (dedupe.contains(normalized)) continue;
        try dedupe.put(allocator, normalized, {});
        try refs.append(allocator, try allocator.dupe(u8, normalized));
    }

    return refs;
}

fn collectDollarSkillReferences(allocator: std.mem.Allocator, text: []const u8) !std.ArrayList([]u8) {
    var refs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (refs.items) |entry| allocator.free(entry);
        refs.deinit(allocator);
    }

    var dedupe: std.StringHashMapUnmanaged(void) = .empty;
    defer dedupe.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '$') continue;
        if (index > 0 and !std.ascii.isWhitespace(text[index - 1]) and text[index - 1] != '(' and text[index - 1] != '[') continue;

        var end = index + 1;
        while (end < text.len and isSkillNameChar(text[end])) : (end += 1) {}
        if (end <= index + 1) continue;

        const normalized = text[index + 1 .. end];
        if (dedupe.contains(normalized)) continue;
        try dedupe.put(allocator, normalized, {});
        try refs.append(allocator, try allocator.dupe(u8, normalized));
        index = end - 1;
    }

    return refs;
}

fn isSkillNameChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

fn trimMatchingOuterQuotes(text: []const u8) []const u8 {
    if (text.len >= 2) {
        if ((text[0] == '"' and text[text.len - 1] == '"') or
            (text[0] == '\'' and text[text.len - 1] == '\''))
        {
            return text[1 .. text.len - 1];
        }
    }
    return text;
}

fn readFileForInjection(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try openFileForPath(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, FILE_INJECT_MAX_FILE_BYTES);
}

fn inspectImageFile(allocator: std.mem.Allocator, path: []const u8, include_sha256: bool) !?ImageFileInfo {
    var file = openFileForPath(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    const bytes = stat.size;
    if (bytes == 0) return null;
    if (bytes > IMAGE_TOOL_MAX_FILE_BYTES) return error.FileTooBig;

    const header_cap: usize = @intCast(@min(bytes, @as(u64, 512 * 1024)));
    var header = try allocator.alloc(u8, header_cap);
    defer allocator.free(header);
    const header_len = try file.readAll(header);
    if (header_len == 0) return null;

    const header_info = parseImageHeader(header[0..header_len]) orelse return null;

    var result: ImageFileInfo = .{
        .bytes = bytes,
        .format = header_info.format,
        .mime = header_info.mime,
        .width = header_info.width,
        .height = header_info.height,
        .sha256_hex = null,
    };

    if (include_sha256) {
        result.sha256_hex = try sha256FileHex(allocator, path);
    }

    return result;
}

const ParsedImageHeader = struct {
    format: []const u8,
    mime: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
};

fn parseImageHeader(bytes: []const u8) ?ParsedImageHeader {
    if (parsePngHeader(bytes)) |parsed| return parsed;
    if (parseJpegHeader(bytes)) |parsed| return parsed;
    if (parseGifHeader(bytes)) |parsed| return parsed;
    if (parseBmpHeader(bytes)) |parsed| return parsed;
    if (parseWebpHeader(bytes)) |parsed| return parsed;
    return null;
}

fn parsePngHeader(bytes: []const u8) ?ParsedImageHeader {
    if (bytes.len < 24) return null;
    const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (!std.mem.eql(u8, bytes[0..8], png_signature[0..])) return null;
    const width = readU32Be(bytes[16..20]);
    const height = readU32Be(bytes[20..24]);
    return .{
        .format = "png",
        .mime = "image/png",
        .width = width,
        .height = height,
    };
}

fn parseGifHeader(bytes: []const u8) ?ParsedImageHeader {
    if (bytes.len < 10) return null;
    const sig = bytes[0..6];
    if (!std.mem.eql(u8, sig, "GIF87a") and !std.mem.eql(u8, sig, "GIF89a")) return null;
    const width = readU16Le(bytes[6..8]);
    const height = readU16Le(bytes[8..10]);
    return .{
        .format = "gif",
        .mime = "image/gif",
        .width = width,
        .height = height,
    };
}

fn parseBmpHeader(bytes: []const u8) ?ParsedImageHeader {
    if (bytes.len < 26) return null;
    if (!std.mem.eql(u8, bytes[0..2], "BM")) return null;

    const width_i32 = @as(i32, @bitCast(readU32Le(bytes[18..22])));
    const height_i32 = @as(i32, @bitCast(readU32Le(bytes[22..26])));
    const width: u32 = if (width_i32 < 0) @as(u32, @intCast(-width_i32)) else @as(u32, @intCast(width_i32));
    const height: u32 = if (height_i32 < 0) @as(u32, @intCast(-height_i32)) else @as(u32, @intCast(height_i32));

    return .{
        .format = "bmp",
        .mime = "image/bmp",
        .width = width,
        .height = height,
    };
}

fn parseJpegHeader(bytes: []const u8) ?ParsedImageHeader {
    if (bytes.len < 4) return null;
    if (bytes[0] != 0xff or bytes[1] != 0xd8) return null;

    var index: usize = 2;
    while (index + 3 < bytes.len) {
        if (bytes[index] != 0xff) {
            index += 1;
            continue;
        }

        while (index < bytes.len and bytes[index] == 0xff) : (index += 1) {}
        if (index >= bytes.len) break;

        const marker = bytes[index];
        index += 1;

        if (marker == 0xd8 or marker == 0xd9) continue;
        if (marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) continue;
        if (index + 1 >= bytes.len) break;

        const segment_len = readU16Be(bytes[index .. index + 2]);
        if (segment_len < 2) break;
        if (index + segment_len > bytes.len) break;

        if (isJpegStartOfFrameMarker(marker) and segment_len >= 7) {
            const height = readU16Be(bytes[index + 3 .. index + 5]);
            const width = readU16Be(bytes[index + 5 .. index + 7]);
            return .{
                .format = "jpeg",
                .mime = "image/jpeg",
                .width = width,
                .height = height,
            };
        }

        index += segment_len;
    }

    return .{
        .format = "jpeg",
        .mime = "image/jpeg",
    };
}

fn parseWebpHeader(bytes: []const u8) ?ParsedImageHeader {
    if (bytes.len < 16) return null;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return null;
    if (!std.mem.eql(u8, bytes[8..12], "WEBP")) return null;

    var index: usize = 12;
    while (index + 8 <= bytes.len) {
        const chunk_tag = bytes[index .. index + 4];
        const chunk_size = readU32Le(bytes[index + 4 .. index + 8]);
        const payload_start = index + 8;
        if (payload_start > bytes.len) break;
        const chunk_bytes = @as(usize, @intCast(chunk_size));
        if (payload_start + chunk_bytes > bytes.len) break;
        const payload = bytes[payload_start .. payload_start + chunk_bytes];

        if (std.mem.eql(u8, chunk_tag, "VP8X") and payload.len >= 10) {
            const width_minus_one = readU24Le(payload[4..7]);
            const height_minus_one = readU24Le(payload[7..10]);
            return .{
                .format = "webp",
                .mime = "image/webp",
                .width = width_minus_one + 1,
                .height = height_minus_one + 1,
            };
        }

        if (std.mem.eql(u8, chunk_tag, "VP8 ") and payload.len >= 10) {
            if (!(payload[3] == 0x9d and payload[4] == 0x01 and payload[5] == 0x2a)) {
                return .{ .format = "webp", .mime = "image/webp" };
            }
            const width = readU16Le(payload[6..8]) & 0x3fff;
            const height = readU16Le(payload[8..10]) & 0x3fff;
            return .{
                .format = "webp",
                .mime = "image/webp",
                .width = width,
                .height = height,
            };
        }

        if (std.mem.eql(u8, chunk_tag, "VP8L") and payload.len >= 5 and payload[0] == 0x2f) {
            const width = 1 + @as(u32, payload[1]) + (@as(u32, payload[2] & 0x3f) << 8);
            const height = 1 + (@as(u32, payload[2] >> 6) | (@as(u32, payload[3]) << 2) | (@as(u32, payload[4] & 0x0f) << 10));
            return .{
                .format = "webp",
                .mime = "image/webp",
                .width = width,
                .height = height,
            };
        }

        const padded_chunk_bytes = chunk_bytes + (chunk_bytes & 1);
        index = payload_start + padded_chunk_bytes;
    }

    return .{
        .format = "webp",
        .mime = "image/webp",
    };
}

fn sha256FileHex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try openFileForPath(path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    while (true) {
        const read_len = try file.read(buffer[0..]);
        if (read_len == 0) break;
        hasher.update(buffer[0..read_len]);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &digest_hex);
}

fn isJpegStartOfFrameMarker(marker: u8) bool {
    return switch (marker) {
        0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => true,
        else => false,
    };
}

fn readU16Le(bytes: []const u8) u16 {
    std.debug.assert(bytes.len >= 2);
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU16Be(bytes: []const u8) u16 {
    std.debug.assert(bytes.len >= 2);
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readU24Le(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 3);
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
}

fn readU32Le(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn readU32Be(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | @as(u32, bytes[3]);
}

fn captureClipboardImage(allocator: std.mem.Allocator) !ClipboardImageCapture {
    if (try captureClipboardImageWayland(allocator)) |capture| return capture;
    if (try captureClipboardImageX11(allocator)) |capture| return capture;
    return error.ClipboardImageUnavailable;
}

fn captureClipboardImageWayland(allocator: std.mem.Allocator) !?ClipboardImageCapture {
    const types_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "wl-paste", "--list-types" },
        .cwd = ".",
        .max_output_bytes = 16 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(types_result.stdout);
    defer allocator.free(types_result.stderr);

    switch (types_result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const mime = selectClipboardImageMime(types_result.stdout) orelse return null;

    const image_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "wl-paste", "--no-newline", "--type", mime },
        .cwd = ".",
        .max_output_bytes = CLIPBOARD_IMAGE_MAX_BYTES,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(image_result.stderr);

    switch (image_result.term) {
        .Exited => |code| if (code != 0) {
            allocator.free(image_result.stdout);
            return null;
        },
        else => {
            allocator.free(image_result.stdout);
            return null;
        },
    }

    if (image_result.stdout.len == 0) {
        allocator.free(image_result.stdout);
        return null;
    }

    return .{
        .bytes = image_result.stdout,
        .mime = mime,
    };
}

fn captureClipboardImageX11(allocator: std.mem.Allocator) !?ClipboardImageCapture {
    const targets_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
        .cwd = ".",
        .max_output_bytes = 16 * 1024,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(targets_result.stdout);
    defer allocator.free(targets_result.stderr);

    switch (targets_result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const mime = selectClipboardImageMime(targets_result.stdout) orelse return null;

    const image_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "xclip", "-selection", "clipboard", "-t", mime, "-o" },
        .cwd = ".",
        .max_output_bytes = CLIPBOARD_IMAGE_MAX_BYTES,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(image_result.stderr);

    switch (image_result.term) {
        .Exited => |code| if (code != 0) {
            allocator.free(image_result.stdout);
            return null;
        },
        else => {
            allocator.free(image_result.stdout);
            return null;
        },
    }

    if (image_result.stdout.len == 0) {
        allocator.free(image_result.stdout);
        return null;
    }

    return .{
        .bytes = image_result.stdout,
        .mime = mime,
    };
}

fn selectClipboardImageMime(types_output: []const u8) ?[]const u8 {
    const candidates = [_][]const u8{
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
        "image/bmp",
    };

    for (candidates) |mime| {
        if (containsAsciiIgnoreCase(types_output, mime)) return mime;
    }
    return null;
}

fn extensionForImageMime(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "jpg";
    if (std.mem.eql(u8, mime, "image/webp")) return "webp";
    if (std.mem.eql(u8, mime, "image/gif")) return "gif";
    if (std.mem.eql(u8, mime, "image/bmp")) return "bmp";
    return "img";
}

fn isOpenAiCompatibleProviderId(provider_id: []const u8) bool {
    return std.mem.eql(u8, provider_id, "openai") or
        std.mem.eql(u8, provider_id, "openrouter") or
        std.mem.eql(u8, provider_id, "opencode") or
        std.mem.eql(u8, provider_id, "zenmux");
}

fn defaultBaseUrlForProviderId(provider_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) return "https://api.openai.com/v1";
    if (std.mem.eql(u8, provider_id, "openrouter")) return "https://openrouter.ai/api/v1";
    if (std.mem.eql(u8, provider_id, "opencode")) return "https://opencode.ai/zen/v1";
    if (std.mem.eql(u8, provider_id, "zenmux")) return "https://zenmux.ai/api/v1";
    return null;
}

fn defaultVisionModelForProvider(provider_id: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_id, "openai")) return "gpt-4.1-mini";
    if (std.mem.eql(u8, provider_id, "openrouter")) return "openai/gpt-4.1-mini";
    if (std.mem.eql(u8, provider_id, "opencode")) return "openai/gpt-4.1-mini";
    if (std.mem.eql(u8, provider_id, "zenmux")) return "openai/gpt-4.1-mini";
    return "";
}

fn trimTrailingSlashLocal(text: []const u8) []const u8 {
    if (text.len == 0) return text;
    if (text[text.len - 1] == '/') return text[0 .. text.len - 1];
    return text;
}

fn loadImageAsDataUrl(
    allocator: std.mem.Allocator,
    path: []const u8,
    mime: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try openFileForPath(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, max_bytes);
    defer allocator.free(bytes);
    if (bytes.len == max_bytes) {
        const stat = try file.stat();
        if (stat.size > max_bytes) return error.FileTooBig;
    }

    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);

    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime, encoded });
}

fn readHttpResponseBodyAlloc(allocator: std.mem.Allocator, response: *std.http.Client.Response) ![]u8 {
    var transfer_buffer: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [64 * 1024]u8 = undefined;
    var reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);

    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    _ = reader.streamRemaining(&body_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => return err,
    };

    return body_writer.toOwnedSlice();
}

fn formatHttpErrorDetail(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    body: []const u8,
) ![]u8 {
    var sanitized: [220]u8 = undefined;
    const preview = sanitizePreview(body, &sanitized);
    return std.fmt.allocPrint(allocator, "status={s} body={s}", .{ @tagName(status), preview });
}

fn sanitizePreview(input: []const u8, out: []u8) []const u8 {
    if (out.len == 0) return "";
    var written: usize = 0;
    for (input) |ch| {
        if (written >= out.len) break;
        out[written] = if (std.ascii.isPrint(ch) and ch != '\n' and ch != '\r' and ch != '\t') ch else ' ';
        written += 1;
    }
    return std.mem.trim(u8, out[0..written], " ");
}

fn parseVisionCaptionFromChatCompletionsAlloc(
    allocator: std.mem.Allocator,
    response_body: []const u8,
) !?[]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const choices_value = jsonValueObjectField(parsed.value, "choices") orelse return null;
    const first_choice = jsonValueFirstArrayItem(choices_value) orelse return null;
    const message_value = jsonValueObjectField(first_choice, "message") orelse return null;
    const content_value = jsonValueObjectField(message_value, "content") orelse return null;

    switch (content_value) {
        .string => |text| {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) return null;
            return @as(?[]u8, try allocator.dupe(u8, trimmed));
        },
        .array => |items| {
            var writer: std.Io.Writer.Allocating = .init(allocator);
            defer writer.deinit();
            var has_text = false;

            for (items.items) |item| {
                const item_type = if (jsonValueObjectField(item, "type")) |value| switch (value) {
                    .string => |text| text,
                    else => "",
                } else "";

                if (std.mem.eql(u8, item_type, "text")) {
                    const text_value = jsonValueObjectField(item, "text") orelse continue;
                    const text = switch (text_value) {
                        .string => |s| s,
                        else => continue,
                    };
                    const trimmed = std.mem.trim(u8, text, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    if (has_text) try writer.writer.writeByte('\n');
                    try writer.writer.writeAll(trimmed);
                    has_text = true;
                }
            }

            const built = try writer.toOwnedSlice();
            if (built.len == 0) {
                allocator.free(built);
                return null;
            }
            return @as(?[]u8, built);
        },
        else => return null,
    }
}

fn jsonValueObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(key),
        else => null,
    };
}

fn jsonObjectFieldString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn jsonValueFirstArrayItem(value: std.json.Value) ?std.json.Value {
    return switch (value) {
        .array => |array| if (array.items.len > 0) array.items[0] else null,
        else => null,
    };
}

fn resolveCodexAuthPath(allocator: std.mem.Allocator) !?[]u8 {
    const from_codex_home = std.process.getEnvVarOwned(allocator, "CODEX_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (from_codex_home) |codex_home| {
        defer allocator.free(codex_home);
        return @as(?[]u8, try std.fs.path.join(allocator, &.{ codex_home, "auth.json" }));
    }

    const from_home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (from_home) |home| {
        defer allocator.free(home);
        return @as(?[]u8, try std.fs.path.join(allocator, &.{ home, ".codex", "auth.json" }));
    }

    return null;
}

fn resolveOpenCodeAuthPath(allocator: std.mem.Allocator) !?[]u8 {
    const from_data_home = std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (from_data_home) |data_home| {
        defer allocator.free(data_home);
        return @as(?[]u8, try std.fs.path.join(allocator, &.{ data_home, "opencode", "auth.json" }));
    }

    const from_home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (from_home) |home| {
        defer allocator.free(home);
        return @as(?[]u8, try std.fs.path.join(allocator, &.{ home, ".local", "share", "opencode", "auth.json" }));
    }

    return null;
}

fn extractChatgptAccountIdFromJwtAlloc(allocator: std.mem.Allocator, jwt: []const u8) !?[]u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return null;
    const payload_b64 = parts.next() orelse return null;
    _ = parts.next() orelse return null;

    const decoded_cap = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch return null;
    if (decoded_cap == 0) return null;

    const decoded_payload = try allocator.alloc(u8, decoded_cap);
    defer allocator.free(decoded_payload);

    std.base64.url_safe_no_pad.Decoder.decode(decoded_payload, payload_b64) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded_payload, .{}) catch return null;
    defer parsed.deinit();

    const claims = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };

    const raw_account = extractChatgptAccountIdFromClaims(claims) orelse return null;
    const account_id = std.mem.trim(u8, raw_account, " \t\r\n");
    if (account_id.len == 0) return null;
    return @as(?[]u8, try allocator.dupe(u8, account_id));
}

fn extractChatgptAccountIdFromClaims(claims: std.json.ObjectMap) ?[]const u8 {
    if (jsonObjectFieldString(claims, "chatgpt_account_id")) |account_id| {
        return account_id;
    }

    if (claims.get("https://api.openai.com/auth")) |auth_value| {
        switch (auth_value) {
            .object => |auth_object| {
                if (jsonObjectFieldString(auth_object, "chatgpt_account_id")) |account_id| {
                    return account_id;
                }
            },
            else => {},
        }
    }

    if (claims.get("organizations")) |organizations_value| {
        switch (organizations_value) {
            .array => |organizations| {
                for (organizations.items) |entry| {
                    switch (entry) {
                        .object => |organization| {
                            if (jsonObjectFieldString(organization, "id")) |account_id| {
                                return account_id;
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    return null;
}

const SkillRoot = struct {
    path: []u8,
    scope: SkillScope,
};

fn discoverSkillsAlloc(allocator: std.mem.Allocator) !std.ArrayList(SkillInfo) {
    var skills: std.ArrayList(SkillInfo) = .empty;
    errdefer {
        for (skills.items) |*skill| skill.deinit(allocator);
        skills.deinit(allocator);
    }

    var roots = try collectSkillRootsAlloc(allocator);
    defer {
        for (roots.items) |root| allocator.free(root.path);
        roots.deinit(allocator);
    }

    for (roots.items) |root| {
        try discoverSkillsUnderRoot(allocator, &skills, root);
    }

    return skills;
}

fn collectSkillRootsAlloc(allocator: std.mem.Allocator) !std.ArrayList(SkillRoot) {
    var roots: std.ArrayList(SkillRoot) = .empty;
    errdefer {
        for (roots.items) |root| allocator.free(root.path);
        roots.deinit(allocator);
    }

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (home_dir) |value| allocator.free(value);

    const xdg_config_home = try resolveXdgConfigHomeAlloc(allocator);
    defer if (xdg_config_home) |value| allocator.free(value);

    const codex_home = std.process.getEnvVarOwned(allocator, "CODEX_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (codex_home) |value| allocator.free(value);

    if (xdg_config_home) |config_home| {
        try appendSkillRootFromParts(allocator, &roots, config_home, "opencode/skill", .global);
        try appendSkillRootFromParts(allocator, &roots, config_home, "opencode/skills", .global);
        try appendSkillRootFromParts(allocator, &roots, config_home, "zolt/skill", .global);
        try appendSkillRootFromParts(allocator, &roots, config_home, "zolt/skills", .global);
    }

    if (home_dir) |home| {
        try appendSkillRootFromParts(allocator, &roots, home, ".claude/skills", .global);
        try appendSkillRootFromParts(allocator, &roots, home, ".agents/skills", .global);
        try appendSkillRootFromParts(allocator, &roots, home, ".zolt/skill", .global);
        try appendSkillRootFromParts(allocator, &roots, home, ".zolt/skills", .global);
    }
    if (codex_home) |codex| {
        try appendSkillRootFromParts(allocator, &roots, codex, "skills", .global);
    } else if (home_dir) |home| {
        try appendSkillRootFromParts(allocator, &roots, home, ".codex/skills", .global);
    }

    const cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd);
    const repo_root = try findGitTopLevelAlloc(allocator);
    defer if (repo_root) |path| allocator.free(path);

    var ancestors = try collectAncestorsUpToRepoAlloc(allocator, cwd, repo_root);
    defer {
        for (ancestors.items) |dir| allocator.free(dir);
        ancestors.deinit(allocator);
    }

    var idx = ancestors.items.len;
    while (idx > 0) : (idx -= 1) {
        const base = ancestors.items[idx - 1];
        try appendSkillRootFromParts(allocator, &roots, base, ".opencode/skill", .project);
        try appendSkillRootFromParts(allocator, &roots, base, ".opencode/skills", .project);
        try appendSkillRootFromParts(allocator, &roots, base, ".claude/skills", .project);
        try appendSkillRootFromParts(allocator, &roots, base, ".agents/skills", .project);
        try appendSkillRootFromParts(allocator, &roots, base, ".codex/skills", .project);
    }

    return roots;
}

fn resolveXdgConfigHomeAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const from_env = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (from_env) |value| return value;

    const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    if (home_dir) |home| {
        defer allocator.free(home);
        return try std.fs.path.join(allocator, &.{ home, ".config" });
    }
    return null;
}

fn collectAncestorsUpToRepoAlloc(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    repo_root: ?[]const u8,
) !std.ArrayList([]u8) {
    var dirs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (dirs.items) |dir| allocator.free(dir);
        dirs.deinit(allocator);
    }

    var current = try allocator.dupe(u8, cwd);
    while (true) {
        try dirs.append(allocator, current);
        if (repo_root) |root| {
            if (std.mem.eql(u8, current, root)) break;
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == current.len) break;
        current = try allocator.dupe(u8, parent);
    }

    return dirs;
}

fn appendSkillRootFromParts(
    allocator: std.mem.Allocator,
    roots: *std.ArrayList(SkillRoot),
    base: []const u8,
    relative: []const u8,
    scope: SkillScope,
) !void {
    const path = try std.fs.path.join(allocator, &.{ base, relative });
    errdefer allocator.free(path);

    var dir = openDirForPath(path, .{}) catch {
        allocator.free(path);
        return;
    };
    dir.close();

    for (roots.items) |existing| {
        if (std.mem.eql(u8, existing.path, path)) {
            allocator.free(path);
            return;
        }
    }

    try roots.append(allocator, .{
        .path = path,
        .scope = scope,
    });
}

fn discoverSkillsUnderRoot(
    allocator: std.mem.Allocator,
    skills: *std.ArrayList(SkillInfo),
    root: SkillRoot,
) !void {
    var dir = openDirForPath(root.path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(entry.path), "SKILL.md")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ root.path, entry.path });
        defer allocator.free(full_path);

        const skill = try parseSkillFileAlloc(allocator, full_path, root.scope) orelse continue;
        try upsertSkill(allocator, skills, skill);
    }
}

fn parseSkillFileAlloc(
    allocator: std.mem.Allocator,
    skill_path: []const u8,
    scope: SkillScope,
) !?SkillInfo {
    var file = openFileForPath(skill_path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, SKILL_FILE_MAX_BYTES) catch return null;
    defer allocator.free(content);

    const frontmatter = parseSkillFrontmatter(content) orelse return null;
    const name = frontmatter.name;
    const description = frontmatter.description;
    if (!isValidSkillName(name)) return null;

    const base_dir = std.fs.path.dirname(skill_path) orelse return null;
    const dir_name = std.fs.path.basename(base_dir);
    if (!std.ascii.eqlIgnoreCase(name, dir_name)) return null;

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .path = try allocator.dupe(u8, skill_path),
        .base_dir = try allocator.dupe(u8, base_dir),
        .scope = scope,
    };
}

const ParsedSkillFrontmatter = struct {
    name: []const u8,
    description: []const u8,
};

fn parseSkillFrontmatter(content: []const u8) ?ParsedSkillFrontmatter {
    var text = content;
    if (text.len >= 3 and text[0] == 0xef and text[1] == 0xbb and text[2] == 0xbf) {
        text = text[3..];
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    const first_raw = lines.next() orelse return null;
    const first = std.mem.trimRight(u8, first_raw, "\r");
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " \t"), "---")) return null;

    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (std.mem.eql(u8, line, "---")) break;
        if (std.mem.startsWith(u8, line, "name:")) {
            name = trimFrontmatterValue(line["name:".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "description:")) {
            description = trimFrontmatterValue(line["description:".len..]);
            continue;
        }
    }

    const parsed_name = name orelse return null;
    const parsed_description = description orelse return null;
    if (parsed_name.len == 0 or parsed_description.len == 0) return null;
    return .{
        .name = parsed_name,
        .description = parsed_description,
    };
}

fn trimFrontmatterValue(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    return trimMatchingOuterQuotes(trimmed);
}

fn isValidSkillName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;

    var previous_dash = false;
    for (name) |byte| {
        const is_dash = byte == '-';
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or is_dash)) return false;
        if (is_dash and previous_dash) return false;
        previous_dash = is_dash;
    }
    return true;
}

fn upsertSkill(
    allocator: std.mem.Allocator,
    skills: *std.ArrayList(SkillInfo),
    skill: SkillInfo,
) !void {
    for (skills.items, 0..) |*existing, index| {
        if (!std.ascii.eqlIgnoreCase(existing.name, skill.name)) continue;
        existing.deinit(allocator);
        skills.items[index] = skill;
        return;
    }
    try skills.append(allocator, skill);
}

fn buildSkillsContextPayloadAlloc(allocator: std.mem.Allocator, skills: []const SkillInfo) ![]u8 {
    if (skills.len == 0) return allocator.dupe(u8, "");

    const cwd = std.process.getCwdAlloc(allocator) catch null;
    defer if (cwd) |path| allocator.free(path);
    const repo_root = findGitTopLevelAlloc(allocator) catch null;
    defer if (repo_root) |path| allocator.free(path);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print(
        "{s} available:{d}\nUse $skill-name mention or <SKILL>{{\"name\":\"...\"}}</SKILL> to load full instructions.\n<available_skills>\n",
        .{ SKILLS_CONTEXT_HEADER, skills.len },
    );

    const shown = @min(skills.len, SKILLS_CONTEXT_MAX_ENTRIES);
    for (skills[0..shown]) |skill| {
        const display_path = try formatInjectedPathForSummaryAlloc(allocator, skill.path, cwd, repo_root);
        defer allocator.free(display_path);
        try out.writer.print(
            "- {s}: {s} (scope:{s} path:{s})\n",
            .{ skill.name, skill.description, switch (skill.scope) {
                .project => "project",
                .global => "global",
            }, display_path },
        );
    }
    if (skills.len > shown) {
        try out.writer.print("- ... (+{d} more)\n", .{skills.len - shown});
    }
    try out.writer.writeAll("</available_skills>\n");

    return out.toOwnedSlice();
}

fn findNearestAgentsFilePathAlloc(allocator: std.mem.Allocator) !?[]u8 {
    var current_dir = try std.process.getCwdAlloc(allocator);
    const file_names = [_][]const u8{ "AGENTS.md", "agents.md" };

    while (true) {
        for (file_names) |file_name| {
            const candidate = try std.fs.path.join(allocator, &.{ current_dir, file_name });

            var file = openFileForPath(candidate, .{}) catch |err| {
                switch (err) {
                    error.FileNotFound, error.NotDir => {
                        allocator.free(candidate);
                        continue;
                    },
                    else => {
                        allocator.free(candidate);
                        allocator.free(current_dir);
                        return err;
                    },
                }
            };
            file.close();

            allocator.free(current_dir);
            return @as(?[]u8, candidate);
        }

        const parent = std.fs.path.dirname(current_dir) orelse {
            allocator.free(current_dir);
            return null;
        };

        const next_dir = try allocator.dupe(u8, parent);
        allocator.free(current_dir);
        current_dir = next_dir;
    }
}

fn readAgentsContextPayloadAlloc(allocator: std.mem.Allocator, agents_path: []const u8) ![]u8 {
    var file = try openFileForPath(agents_path, .{});
    defer file.close();

    const raw_content = try file.readToEndAlloc(allocator, AGENTS_CONTEXT_MAX_FILE_BYTES);
    defer allocator.free(raw_content);

    const trimmed = std.mem.trim(u8, raw_content, " \t\r\n");
    if (trimmed.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}\nsource: {s}\nworkspace_instructions:\n(no content)", .{
            AGENTS_CONTEXT_HEADER,
            agents_path,
        });
    }

    const instructions = try truncateAgentsInstructionsAlloc(allocator, trimmed);
    defer allocator.free(instructions);

    const skills_summary = try extractAvailableSkillsSummaryAlloc(allocator, trimmed);
    defer if (skills_summary) |summary| allocator.free(summary);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.print("{s}\nsource: {s}\nworkspace_instructions:\n{s}", .{
        AGENTS_CONTEXT_HEADER,
        agents_path,
        instructions,
    });

    if (skills_summary) |summary| {
        try out.writer.writeAll("\n\navailable_skills (lazy metadata only):\n");
        try out.writer.writeAll(summary);
    }

    return out.toOwnedSlice();
}

fn truncateAgentsInstructionsAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= AGENTS_CONTEXT_MAX_INSTRUCTIONS_BYTES) {
        return allocator.dupe(u8, text);
    }

    const omitted_bytes = text.len - AGENTS_CONTEXT_MAX_INSTRUCTIONS_BYTES;
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\n[... AGENTS instructions truncated, omitted {d} bytes ...]",
        .{ text[0..AGENTS_CONTEXT_MAX_INSTRUCTIONS_BYTES], omitted_bytes },
    );
}

fn extractAvailableSkillsSummaryAlloc(allocator: std.mem.Allocator, agents_text: []const u8) !?[]u8 {
    var lines = std.mem.splitScalar(u8, agents_text, '\n');
    var in_available_skills = false;
    var has_items = false;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        if (std.mem.startsWith(u8, trimmed, "### ")) {
            if (in_available_skills) break;
            in_available_skills = std.ascii.eqlIgnoreCase(trimmed, "### Available skills");
            continue;
        }

        if (!in_available_skills) continue;
        if (!std.mem.startsWith(u8, trimmed, "- ")) continue;

        const bullet_body = std.mem.trim(u8, trimmed[2..], " ");
        if (bullet_body.len == 0) continue;

        const colon_index = std.mem.indexOfScalar(u8, bullet_body, ':') orelse continue;
        const skill_name = std.mem.trim(u8, bullet_body[0..colon_index], " ");
        const skill_description = std.mem.trim(u8, bullet_body[colon_index + 1 ..], " ");
        if (skill_name.len == 0 or skill_description.len == 0) continue;

        if (has_items) try out.writer.writeByte('\n');
        try out.writer.print("- {s}: {s}", .{ skill_name, skill_description });
        has_items = true;
    }

    if (!has_items) return null;
    return @as(?[]u8, try out.toOwnedSlice());
}

fn openDirForPath(path: []const u8, flags: std.fs.Dir.OpenOptions) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openDirAbsolute(path, flags);
    }
    return std.fs.cwd().openDir(path, flags);
}

fn openFileForPath(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, flags);
    }
    return std.fs.cwd().openFile(path, flags);
}

fn dirEntryKindLabel(kind: std.fs.Dir.Entry.Kind) []const u8 {
    return switch (kind) {
        .directory => "dir",
        .file => "file",
        .sym_link => "link",
        .named_pipe => "pipe",
        .character_device => "char",
        .block_device => "block",
        .unix_domain_socket => "sock",
        else => "other",
    };
}

const ParsedRgLine = struct {
    path: []const u8,
    line: u32,
    col: u32,
    text: []const u8,
};

fn parseRgLine(line: []const u8) ?ParsedRgLine {
    const first = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, line, first + 1, ':') orelse return null;
    const third = std.mem.indexOfScalarPos(u8, line, second + 1, ':') orelse return null;
    if (first == 0 or second <= first + 1 or third <= second + 1) return null;

    const line_no = std.fmt.parseInt(u32, line[first + 1 .. second], 10) catch return null;
    const col_no = std.fmt.parseInt(u32, line[second + 1 .. third], 10) catch return null;
    return .{
        .path = line[0..first],
        .line = line_no,
        .col = col_no,
        .text = line[third + 1 ..],
    };
}

fn projectSearchHitLessThan(_: void, lhs: ProjectSearchFileHit, rhs: ProjectSearchFileHit) bool {
    if (lhs.hits != rhs.hits) return lhs.hits > rhs.hits;
    if (lhs.first_line != rhs.first_line) return lhs.first_line < rhs.first_line;
    return std.mem.lessThan(u8, lhs.path, rhs.path);
}

fn looksBinary(content: []const u8) bool {
    if (std.mem.indexOfScalar(u8, content, 0) != null) return true;
    if (content.len == 0) return false;

    const sample_len = @min(content.len, 1024);
    var control_count: usize = 0;
    for (content[0..sample_len]) |byte| {
        if (byte == '\n' or byte == '\r' or byte == '\t') continue;
        if (byte < 0x20 or byte == 0x7f) control_count += 1;
    }
    return control_count * 10 > sample_len;
}

fn summarizeToolResultAlloc(allocator: std.mem.Allocator, tool_result: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, tool_result, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "(no output)");

    if (findNamedLineValue(trimmed, "state:")) |state| {
        return std.fmt.allocPrint(allocator, "state:{s}", .{state});
    }
    if (findNamedLineValue(trimmed, "error:")) |err_text| {
        return std.fmt.allocPrint(allocator, "error:{s}", .{err_text});
    }
    if (findNamedLineValue(trimmed, "status:")) |status| {
        return std.fmt.allocPrint(allocator, "status:{s}", .{status});
    }

    if (firstNonEmptyLine(trimmed)) |line| {
        const max_len: usize = 120;
        if (line.len <= max_len) return allocator.dupe(u8, line);
        return std.fmt.allocPrint(allocator, "{s}...", .{line[0..max_len]});
    }
    return allocator.dupe(u8, "(no output)");
}

fn isToolMarkerLikeResponse(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return true;
    return parseAssistantToolCall(trimmed) != null;
}

fn displayToolNameAlloc(allocator: std.mem.Allocator, tool_call: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, tool_call, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "[tool]")) {
        const rest = std.mem.trimLeft(u8, trimmed["[tool]".len..], " \t");
        if (rest.len > 0) return allocator.dupe(u8, rest);
    }
    return allocator.dupe(u8, trimmed);
}

fn buildToolFallbackSummaryFromLastToolAlloc(
    allocator: std.mem.Allocator,
    last_tool_call: ?[]const u8,
    last_tool_summary: ?[]const u8,
    reason: []const u8,
) ![]u8 {
    if (last_tool_call) |tool_call| {
        const display_tool = try displayToolNameAlloc(allocator, tool_call);
        defer allocator.free(display_tool);
        const summary = last_tool_summary orelse "(no result summary)";
        return std.fmt.allocPrint(
            allocator,
            "I completed `{s}`. Last tool result: {s}. I stopped further tool calls ({s}) and this is the best available outcome.",
            .{ display_tool, summary, reason },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "I could not produce a final model summary after tool execution ({s}), and no tool result summary is available.",
        .{reason},
    );
}

fn sanitizeFinalUserFacingResponseAlloc(
    allocator: std.mem.Allocator,
    candidate: []const u8,
    last_tool_call: ?[]const u8,
    last_tool_summary: ?[]const u8,
    reason: []const u8,
) ![]u8 {
    if (!isToolMarkerLikeResponse(candidate)) return allocator.dupe(u8, candidate);
    return buildToolFallbackSummaryFromLastToolAlloc(allocator, last_tool_call, last_tool_summary, reason);
}

fn findNamedLineValue(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        return std.mem.trim(u8, line[prefix.len..], " \t");
    }
    return null;
}

fn firstNonEmptyLine(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (line.len == 0) continue;
        return line;
    }
    return null;
}

fn didRepeatToolExecution(
    allocator: std.mem.Allocator,
    seen_signatures: *std.ArrayList([]u8),
    tool_name: []const u8,
    args: []const u8,
    result: []const u8,
) !bool {
    const signature = try std.fmt.allocPrint(
        allocator,
        "{s}\n--args--\n{s}\n--result--\n{s}",
        .{ tool_name, args, result },
    );

    for (seen_signatures.items) |existing| {
        if (std.mem.eql(u8, existing, signature)) {
            allocator.free(signature);
            return true;
        }
    }
    try seen_signatures.append(allocator, signature);
    return false;
}

fn isAllowedReadCommand(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const command = argv[0];
    if (command.len == 0) return false;
    if (std.mem.indexOfScalar(u8, command, '/')) |_| return false;

    if (std.mem.eql(u8, command, "git")) {
        return isAllowedReadGitCommand(argv[1..]);
    }

    const allowlist = [_][]const u8{
        "rg",
        "grep",
        "ls",
        "cat",
        "find",
        "head",
        "tail",
        "sed",
        "wc",
        "stat",
        "pwd",
    };

    for (allowlist) |allowed| {
        if (std.mem.eql(u8, command, allowed)) return true;
    }
    return false;
}

fn isAllowedReadGitCommand(args: []const []const u8) bool {
    if (args.len == 0) return false;
    const subcommand = args[0];
    if (subcommand.len == 0) return false;
    if (subcommand[0] == '-') return false;

    const allowlist = [_][]const u8{
        "status",
        "diff",
        "show",
        "log",
        "rev-parse",
        "ls-files",
    };

    for (allowlist) |allowed| {
        if (std.mem.eql(u8, subcommand, allowed)) return true;
    }
    return false;
}

fn classifyStreamFailureAlloc(
    allocator: std.mem.Allocator,
    err: anyerror,
    provider_detail: ?[]const u8,
) !StreamFailureInfo {
    if (provider_detail) |detail| {
        const status_tag = statusTagFromProviderDetail(detail);
        const context_related = isContextRelatedProviderDetail(detail);
        const retryable = isRetryableStatusTag(status_tag) or context_related;
        const code = status_tag orelse @errorName(err);
        return .{
            .code = try allocator.dupe(u8, code),
            .message = try allocator.dupe(u8, detail),
            .retryable = retryable,
            .context_related = context_related,
            .source = try allocator.dupe(u8, "provider"),
        };
    }

    const err_name = @errorName(err);
    const retryable = isRetryableLocalError(err_name);
    const context_related = isContextRelatedErrorText(err_name);
    return .{
        .code = try allocator.dupe(u8, err_name),
        .message = try allocator.dupe(u8, err_name),
        .retryable = retryable or context_related,
        .context_related = context_related,
        .source = try allocator.dupe(u8, "local"),
    };
}

fn shouldRetryStreamFailure(info: StreamFailureInfo, attempt: usize) bool {
    if (attempt > 0) return false;
    return info.retryable;
}

fn statusTagFromProviderDetail(detail: []const u8) ?[]const u8 {
    const status_prefix = "status=";
    const start_index = std.mem.indexOf(u8, detail, status_prefix) orelse return null;
    const value_start = start_index + status_prefix.len;
    if (value_start >= detail.len) return null;
    var end = value_start;
    while (end < detail.len and detail[end] != ' ' and detail[end] != ')' and detail[end] != ',' and detail[end] != '\n') : (end += 1) {}
    if (end == value_start) return null;
    return detail[value_start..end];
}

fn isRetryableStatusTag(status_tag: ?[]const u8) bool {
    const tag = status_tag orelse return false;
    return std.mem.eql(u8, tag, "too_many_requests") or
        std.mem.eql(u8, tag, "request_timeout") or
        std.mem.eql(u8, tag, "conflict") or
        std.mem.eql(u8, tag, "bad_gateway") or
        std.mem.eql(u8, tag, "service_unavailable") or
        std.mem.eql(u8, tag, "gateway_timeout");
}

fn isRetryableLocalError(err_name: []const u8) bool {
    return containsAsciiIgnoreCase(err_name, "TimedOut") or
        containsAsciiIgnoreCase(err_name, "Connection") or
        containsAsciiIgnoreCase(err_name, "Network") or
        containsAsciiIgnoreCase(err_name, "BrokenPipe") or
        containsAsciiIgnoreCase(err_name, "WouldBlock");
}

fn isContextRelatedProviderDetail(detail: []const u8) bool {
    return isContextRelatedErrorText(detail) or
        containsAsciiIgnoreCase(detail, "maximum context length") or
        containsAsciiIgnoreCase(detail, "context window") or
        containsAsciiIgnoreCase(detail, "too many tokens") or
        containsAsciiIgnoreCase(detail, "prompt is too long");
}

fn isContextRelatedErrorText(text: []const u8) bool {
    return containsAsciiIgnoreCase(text, "context") and
        (containsAsciiIgnoreCase(text, "length") or
            containsAsciiIgnoreCase(text, "window") or
            containsAsciiIgnoreCase(text, "token"));
}

fn statusToChildTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

fn modelMatchesQuery(model: models.ModelInfo, query: []const u8) bool {
    if (query.len == 0) return true;
    return containsAsciiIgnoreCase(model.id, query) or containsAsciiIgnoreCase(model.name, query);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn parseOpenAiAuthModeName(input: []const u8) ?OpenAiAuthMode {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(trimmed, "api_key")) return .api_key;
    if (std.ascii.eqlIgnoreCase(trimmed, "codex")) return .codex;
    return null;
}

fn openAiAuthModeLabel(mode: OpenAiAuthMode) []const u8 {
    return switch (mode) {
        .auto => "auto",
        .api_key => "api_key",
        .codex => "codex",
    };
}

fn fallbackEnvVars(provider_id: []const u8) []const []const u8 {
    if (std.mem.eql(u8, provider_id, "opencode")) return &.{"OPENCODE_API_KEY"};
    if (std.mem.eql(u8, provider_id, "openai")) return &.{"OPENAI_API_KEY"};
    if (std.mem.eql(u8, provider_id, "openrouter")) return &.{"OPENROUTER_API_KEY"};
    if (std.mem.eql(u8, provider_id, "anthropic")) return &.{"ANTHROPIC_API_KEY"};
    if (std.mem.eql(u8, provider_id, "google")) return &.{ "GOOGLE_GENERATIVE_AI_API_KEY", "GEMINI_API_KEY" };
    if (std.mem.eql(u8, provider_id, "zenmux")) return &.{"ZENMUX_API_KEY"};
    return &.{};
}

fn firstEnvVarForProvider(app: *App, provider_id: []const u8) ?[]const u8 {
    if (app.catalog.findProviderConst(provider_id)) |provider| {
        if (provider.env_vars.items.len > 0) return provider.env_vars.items[0];
    }

    const fallback = fallbackEnvVars(provider_id);
    if (fallback.len > 0) return fallback[0];
    return null;
}

test "parseReadToolCommand extracts command formats" {
    try std.testing.expectEqualStrings("rg --files src", parseReadToolCommand("<READ>\nrg --files src\n</READ>").?);
    try std.testing.expectEqualStrings("ls -la", parseReadToolCommand("READ: ls -la").?);
    try std.testing.expectEqualStrings("cat src/main.zig", parseReadToolCommand("READ cat src/main.zig").?);
    try std.testing.expectEqualStrings("grep -n foo src/tui.zig", parseReadToolCommand("```read\ngrep -n foo src/tui.zig\n```").?);
    try std.testing.expect(parseReadToolCommand("normal assistant text") == null);
}

test "parse list/read/grep/project tool payload formats" {
    try std.testing.expectEqualStrings(
        "{\"path\":\"src\",\"recursive\":true}",
        parseListDirToolPayload("<LIST_DIR>\n{\"path\":\"src\",\"recursive\":true}\n</LIST_DIR>").?,
    );
    try std.testing.expectEqualStrings(
        "{\"path\":\"src/main.zig\"}",
        parseReadFileToolPayload("```read_file\n{\"path\":\"src/main.zig\"}\n```").?,
    );
    try std.testing.expectEqualStrings(
        "{\"query\":\"TODO\",\"path\":\"src\"}",
        parseGrepFilesToolPayload("<GREP_FILES>\n{\"query\":\"TODO\",\"path\":\"src\"}\n</GREP_FILES>").?,
    );
    try std.testing.expectEqualStrings(
        "{\"query\":\"provider\",\"max_files\":4}",
        parseProjectSearchToolPayload("```project_search\n{\"query\":\"provider\",\"max_files\":4}\n```").?,
    );
}

test "parseExecCommandToolPayload extracts xml and fenced formats" {
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"ls -la\"}",
        parseExecCommandToolPayload("<EXEC_COMMAND>\n{\"cmd\":\"ls -la\"}\n</EXEC_COMMAND>").?,
    );
    try std.testing.expectEqualStrings(
        "{\"cmd\":\"pwd\"}",
        parseExecCommandToolPayload("```exec_command\n{\"cmd\":\"pwd\"}\n```").?,
    );
    try std.testing.expect(parseExecCommandToolPayload("no tool") == null);
}

test "parseWriteStdinToolPayload extracts xml and fenced formats" {
    try std.testing.expectEqualStrings(
        "{\"session_id\":3,\"chars\":\"pwd\\n\"}",
        parseWriteStdinToolPayload("<WRITE_STDIN>\n{\"session_id\":3,\"chars\":\"pwd\\n\"}\n</WRITE_STDIN>").?,
    );
    try std.testing.expectEqualStrings(
        "{\"session_id\":2,\"chars\":\"exit\\n\"}",
        parseWriteStdinToolPayload("```write_stdin\n{\"session_id\":2,\"chars\":\"exit\\n\"}\n```").?,
    );
    try std.testing.expect(parseWriteStdinToolPayload("no tool") == null);
}

test "parseWebSearchToolPayload extracts xml and fenced formats" {
    try std.testing.expectEqualStrings(
        "{\"query\":\"zig build system\",\"limit\":3}",
        parseWebSearchToolPayload("<WEB_SEARCH>\n{\"query\":\"zig build system\",\"limit\":3}\n</WEB_SEARCH>").?,
    );
    try std.testing.expectEqualStrings(
        "{\"query\":\"ziglang docs\"}",
        parseWebSearchToolPayload("```web_search\n{\"query\":\"ziglang docs\"}\n```").?,
    );
    try std.testing.expect(parseWebSearchToolPayload("no tool") == null);
}

test "parseViewImageToolPayload extracts xml and fenced formats" {
    try std.testing.expectEqualStrings(
        "{\"path\":\"assets/screenshot.png\"}",
        parseViewImageToolPayload("<VIEW_IMAGE>\n{\"path\":\"assets/screenshot.png\"}\n</VIEW_IMAGE>").?,
    );
    try std.testing.expectEqualStrings(
        "{\"path\":\"/tmp/cap.jpg\"}",
        parseViewImageToolPayload("```view_image\n{\"path\":\"/tmp/cap.jpg\"}\n```").?,
    );
    try std.testing.expect(parseViewImageToolPayload("no tool") == null);
}

test "parseSkillToolPayload extracts xml fenced and bracket formats" {
    try std.testing.expectEqualStrings(
        "{\"name\":\"release\"}",
        parseSkillToolPayload("<SKILL>\n{\"name\":\"release\"}\n</SKILL>").?,
    );
    try std.testing.expectEqualStrings(
        "{\"name\":\"workspace-bootstrap\"}",
        parseSkillToolPayload("```skill\n{\"name\":\"workspace-bootstrap\"}\n```").?,
    );
    try std.testing.expectEqualStrings(
        "lint-fix",
        parseSkillToolPayload("[tool] SKILL lint-fix").?,
    );
    try std.testing.expect(parseSkillToolPayload("no tool") == null);
}

test "parseExecCommandInput parses json and plain command" {
    const allocator = std.testing.allocator;

    const json_input = try parseExecCommandInput(allocator, "{\"cmd\":\"ls -la\",\"yield_ms\":1200}");
    defer allocator.free(json_input.cmd);
    try std.testing.expectEqualStrings("ls -la", json_input.cmd);
    try std.testing.expectEqual(@as(u32, 1200), json_input.yield_ms);

    const plain_input = try parseExecCommandInput(allocator, "pwd");
    defer allocator.free(plain_input.cmd);
    try std.testing.expectEqualStrings("pwd", plain_input.cmd);
    try std.testing.expectEqual(@as(u32, COMMAND_TOOL_DEFAULT_YIELD_MS), plain_input.yield_ms);
}

test "parseWriteStdinInput parses json payload" {
    const allocator = std.testing.allocator;

    const input = try parseWriteStdinInput(
        allocator,
        "{\"session_id\":9,\"chars\":\"echo hi\\n\",\"yield_time_ms\":300}",
    );
    defer allocator.free(input.chars);

    try std.testing.expectEqual(@as(u32, 9), input.session_id);
    try std.testing.expectEqualStrings("echo hi\n", input.chars);
    try std.testing.expectEqual(@as(u32, 300), input.yield_ms);
}

test "parseWebSearchInput parses json and plain query" {
    const allocator = std.testing.allocator;

    const json_input = try parseWebSearchInput(
        allocator,
        "{\"query\":\"zig allocator tutorial\",\"limit\":12,\"engine\":\"exa\"}",
    );
    defer allocator.free(json_input.query);
    try std.testing.expectEqualStrings("zig allocator tutorial", json_input.query);
    try std.testing.expectEqual(@as(u8, WEB_SEARCH_MAX_RESULTS), json_input.limit);
    try std.testing.expect(json_input.engine == .exa);

    const plain_input = try parseWebSearchInput(allocator, "zig async await");
    defer allocator.free(plain_input.query);
    try std.testing.expectEqualStrings("zig async await", plain_input.query);
    try std.testing.expectEqual(@as(u8, WEB_SEARCH_DEFAULT_RESULTS), plain_input.limit);
    try std.testing.expect(plain_input.engine == .duckduckgo);

    try std.testing.expectError(
        error.InvalidToolPayload,
        parseWebSearchInput(allocator, "{\"query\":\"zig\",\"engine\":\"unknown\"}"),
    );
}

test "parseViewImageInput parses json and plain path" {
    const allocator = std.testing.allocator;

    const json_input = try parseViewImageInput(
        allocator,
        "{\"path\":\"assets/image.png\"}",
    );
    defer allocator.free(json_input.path);
    try std.testing.expectEqualStrings("assets/image.png", json_input.path);

    const plain_input = try parseViewImageInput(allocator, "'/tmp/shot.webp'");
    defer allocator.free(plain_input.path);
    try std.testing.expectEqualStrings("/tmp/shot.webp", plain_input.path);
}

test "parseListDirInput parses json and plain payloads" {
    const allocator = std.testing.allocator;

    const json_input = try parseListDirInput(
        allocator,
        "{\"path\":\"src\",\"recursive\":true,\"max_entries\":2048}",
    );
    defer allocator.free(json_input.path);
    try std.testing.expectEqualStrings("src", json_input.path);
    try std.testing.expect(json_input.recursive);
    try std.testing.expectEqual(@as(u16, LIST_DIR_MAX_ENTRIES), json_input.max_entries);

    const plain_input = try parseListDirInput(allocator, ".");
    defer allocator.free(plain_input.path);
    try std.testing.expectEqualStrings(".", plain_input.path);
    try std.testing.expect(!plain_input.recursive);
}

test "parseReadFileInput parses json and plain payloads" {
    const allocator = std.testing.allocator;

    const json_input = try parseReadFileInput(
        allocator,
        "{\"path\":\"src/main.zig\",\"max_bytes\":999999}",
    );
    defer allocator.free(json_input.path);
    try std.testing.expectEqualStrings("src/main.zig", json_input.path);
    try std.testing.expectEqual(@as(u32, READ_FILE_MAX_BYTES), json_input.max_bytes);

    const plain_input = try parseReadFileInput(allocator, "README.md");
    defer allocator.free(plain_input.path);
    try std.testing.expectEqualStrings("README.md", plain_input.path);
}

test "parseGrepFilesInput parses json and plain payloads" {
    const allocator = std.testing.allocator;

    var json_input = try parseGrepFilesInput(
        allocator,
        "{\"query\":\"TODO\",\"path\":\"src\",\"glob\":\"*.zig\",\"max_matches\":99999}",
    );
    defer json_input.deinit(allocator);
    try std.testing.expectEqualStrings("TODO", json_input.query);
    try std.testing.expectEqualStrings("src", json_input.path);
    try std.testing.expectEqualStrings("*.zig", json_input.glob.?);
    try std.testing.expectEqual(@as(u16, GREP_FILES_MAX_MATCHES), json_input.max_matches);

    var plain_input = try parseGrepFilesInput(allocator, "token usage");
    defer plain_input.deinit(allocator);
    try std.testing.expectEqualStrings("token usage", plain_input.query);
    try std.testing.expectEqualStrings(".", plain_input.path);
}

test "parseProjectSearchInput parses json and plain payloads" {
    const allocator = std.testing.allocator;

    var json_input = try parseProjectSearchInput(
        allocator,
        "{\"query\":\"provider\",\"path\":\"src\",\"max_files\":99,\"max_matches\":99999}",
    );
    defer json_input.deinit(allocator);
    try std.testing.expectEqualStrings("provider", json_input.query);
    try std.testing.expectEqualStrings("src", json_input.path);
    try std.testing.expectEqual(@as(u8, PROJECT_SEARCH_MAX_FILES), json_input.max_files);
    try std.testing.expectEqual(@as(u16, PROJECT_SEARCH_MAX_MATCHES), json_input.max_matches);

    var plain_input = try parseProjectSearchInput(allocator, "stream");
    defer plain_input.deinit(allocator);
    try std.testing.expectEqualStrings("stream", plain_input.query);
    try std.testing.expectEqualStrings(".", plain_input.path);
}

test "parseRgLine extracts path line column and text" {
    const parsed = parseRgLine("src/main.zig:42:7:hello world").?;
    try std.testing.expectEqualStrings("src/main.zig", parsed.path);
    try std.testing.expectEqual(@as(u32, 42), parsed.line);
    try std.testing.expectEqual(@as(u32, 7), parsed.col);
    try std.testing.expectEqualStrings("hello world", parsed.text);
}

test "parseDuckDuckGoHtmlResults extracts titles and urls" {
    const allocator = std.testing.allocator;
    const html =
        "<div><a rel=\"nofollow\" class=\"result__a\" href=\"https://example.com/path?a=1&amp;b=2\">Example &amp; One</a></div>\n" ++
        "<div><a class=\"result__a\" href=\"https://duckduckgo.com/l/?uddg=https%3A%2F%2Fziglang.org%2Flearn\">Zig Learn</a></div>\n";

    const results = try parseDuckDuckGoHtmlResults(allocator, html, 5);
    defer {
        for (results) |*item| item.deinit(allocator);
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("Example & One", results[0].title);
    try std.testing.expectEqualStrings("https://example.com/path?a=1&b=2", results[0].url);
    try std.testing.expectEqualStrings("Zig Learn", results[1].title);
    try std.testing.expectEqualStrings("https://ziglang.org/learn", results[1].url);
}

test "parseExaJsonResults extracts titles and urls" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"results":[{"title":"Zig Language","url":"https://ziglang.org/"},{"title":"","url":"https://example.com/fallback-title"},{"url":"https://example.com/no-title-field"}]}
    ;

    const results = try parseExaJsonResults(allocator, payload, 5);
    defer {
        for (results) |*item| item.deinit(allocator);
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("Zig Language", results[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org/", results[0].url);
    try std.testing.expectEqualStrings("https://example.com/fallback-title", results[1].title);
    try std.testing.expectEqualStrings("https://example.com/no-title-field", results[2].title);
}

test "parseVisionCaptionFromChatCompletionsAlloc parses string content" {
    const allocator = std.testing.allocator;
    const body =
        \\{"id":"chatcmpl-x","choices":[{"index":0,"message":{"role":"assistant","content":"This is a UI screenshot with an error banner."}}]}
    ;

    const caption = try parseVisionCaptionFromChatCompletionsAlloc(allocator, body);
    defer if (caption) |text| allocator.free(text);

    try std.testing.expect(caption != null);
    try std.testing.expectEqualStrings("This is a UI screenshot with an error banner.", caption.?);
}

test "parseVisionCaptionFromChatCompletionsAlloc parses content array text parts" {
    const allocator = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"content":[{"type":"text","text":"Line one"},{"type":"text","text":"Line two"}]}}]}
    ;

    const caption = try parseVisionCaptionFromChatCompletionsAlloc(allocator, body);
    defer if (caption) |text| allocator.free(text);

    try std.testing.expect(caption != null);
    try std.testing.expectEqualStrings("Line one\nLine two", caption.?);
}

test "parseApplyPatchToolPayload extracts codex patch formats" {
    const xml_payload =
        "<APPLY_PATCH>\n" ++
        "*** Begin Patch\n" ++
        "*** Update File: src/main.zig\n" ++
        "@@\n" ++
        "-old\n" ++
        "+new\n" ++
        "*** End Patch\n" ++
        "</APPLY_PATCH>";
    try std.testing.expectEqualStrings(
        "*** Begin Patch\n*** Update File: src/main.zig\n@@\n-old\n+new\n*** End Patch",
        parseApplyPatchToolPayload(xml_payload).?,
    );

    const fence_payload =
        "```apply_patch\n" ++
        "*** Begin Patch\n" ++
        "*** Add File: notes.txt\n" ++
        "+hello\n" ++
        "*** End Patch\n" ++
        "```";
    try std.testing.expectEqualStrings(
        "*** Begin Patch\n*** Add File: notes.txt\n+hello\n*** End Patch",
        parseApplyPatchToolPayload(fence_payload).?,
    );

    try std.testing.expect(parseApplyPatchToolPayload("normal assistant text") == null);
}

test "buildApplyPatchPreview keeps diff-relevant lines and truncates" {
    const allocator = std.testing.allocator;
    const patch =
        "*** Begin Patch\n" ++
        "*** Update File: src/main.zig\n" ++
        "@@\n" ++
        "-old\n" ++
        " context line\n" ++
        "+new\n" ++
        "*** End Patch\n";

    const preview = try buildApplyPatchPreview(allocator, patch, 4);
    defer allocator.free(preview.text);

    try std.testing.expectEqual(@as(usize, 4), preview.included_lines);
    try std.testing.expectEqual(@as(usize, 2), preview.omitted_lines);
    try std.testing.expect(std.mem.indexOf(u8, preview.text, "*** Begin Patch") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview.text, "+new") == null);
}

test "diffLineColor classifies add/remove/meta lines" {
    const palette = paletteForTheme(.codex);
    try std.testing.expectEqualStrings(palette.diff_add, diffLineColor("+added", palette));
    try std.testing.expectEqualStrings(palette.diff_remove, diffLineColor("-removed", palette));
    try std.testing.expectEqualStrings(palette.diff_meta, diffLineColor("@@ hunk", palette));
    try std.testing.expectEqualStrings("", diffLineColor("normal line", palette));
}

test "isDiffFenceLanguage recognizes diff-like fences" {
    try std.testing.expect(isDiffFenceLanguage("diff"));
    try std.testing.expect(isDiffFenceLanguage("PATCH"));
    try std.testing.expect(isDiffFenceLanguage("gitdiff"));
    try std.testing.expect(!isDiffFenceLanguage("zig"));
    try std.testing.expect(!isDiffFenceLanguage(""));
}

test "isAllowedReadCommand allows safe read commands and read-only git subcommands" {
    try std.testing.expect(isAllowedReadCommand(&.{ "rg", "TODO", "src" }));
    try std.testing.expect(isAllowedReadCommand(&.{ "cat", "README.md" }));

    try std.testing.expect(isAllowedReadCommand(&.{ "git", "status", "--short" }));
    try std.testing.expect(isAllowedReadCommand(&.{ "git", "diff", "--", "TODO.md" }));
    try std.testing.expect(isAllowedReadCommand(&.{ "git", "log", "--oneline", "-n", "20" }));
    try std.testing.expect(isAllowedReadCommand(&.{ "git", "show", "HEAD~1" }));
    try std.testing.expect(isAllowedReadCommand(&.{ "git", "rev-parse", "--show-toplevel" }));
    try std.testing.expect(isAllowedReadCommand(&.{ "git", "ls-files" }));
}

test "isAllowedReadCommand rejects non-allowlisted and unsafe forms" {
    try std.testing.expect(!isAllowedReadCommand(&.{}));
    try std.testing.expect(!isAllowedReadCommand(&.{"/bin/ls"}));
    try std.testing.expect(!isAllowedReadCommand(&.{ "echo", "hi" }));
    try std.testing.expect(!isAllowedReadCommand(&.{"git"}));
    try std.testing.expect(!isAllowedReadCommand(&.{ "git", "-c", "core.editor=vim", "status" }));
    try std.testing.expect(!isAllowedReadCommand(&.{ "git", "commit", "-m", "x" }));
    try std.testing.expect(!isAllowedReadCommand(&.{ "git", "push" }));
}

test "classifyStreamFailureAlloc parses provider status and retry flags" {
    const allocator = std.testing.allocator;
    const failure = try classifyStreamFailureAlloc(
        allocator,
        error.ProviderRequestFailed,
        "status=too_many_requests body={\"error\":{\"message\":\"rate limit\"}}",
    );
    defer {
        allocator.free(failure.code);
        allocator.free(failure.message);
        allocator.free(failure.source);
    }

    try std.testing.expectEqualStrings("too_many_requests", failure.code);
    try std.testing.expect(failure.retryable);
    try std.testing.expectEqualStrings("provider", failure.source);
}

test "summarizeToolResultAlloc prioritizes state and error lines" {
    const allocator = std.testing.allocator;
    const summary = try summarizeToolResultAlloc(
        allocator,
        "[exec-result]\nsession_id: 1\nstate: exited:0\nstdout:\n(no output)\n",
    );
    defer allocator.free(summary);
    try std.testing.expectEqualStrings("state:exited:0", summary);

    const error_summary = try summarizeToolResultAlloc(allocator, "[read-result]\nerror: command not allowed\n");
    defer allocator.free(error_summary);
    try std.testing.expectEqualStrings("error:command not allowed", error_summary);
}

test "single tool call success yields final natural language" {
    const allocator = std.testing.allocator;
    const final_text = try sanitizeFinalUserFacingResponseAlloc(
        allocator,
        "Created `.volt/tasks/daily.md` with the requested check-in note.",
        "[tool] EXEC_COMMAND",
        "state:exited:0",
        "finalize",
    );
    defer allocator.free(final_text);

    try std.testing.expectEqualStrings(
        "Created `.volt/tasks/daily.md` with the requested check-in note.",
        final_text,
    );
}

test "repeated tool call loop breaks and uses fallback summary" {
    const allocator = std.testing.allocator;
    var seen: std.ArrayList([]u8) = .empty;
    defer {
        for (seen.items) |entry| allocator.free(entry);
        seen.deinit(allocator);
    }

    try std.testing.expect(!(try didRepeatToolExecution(
        allocator,
        &seen,
        "EXEC_COMMAND",
        "{\"cmd\":\"ls\"}",
        "[exec-result]\nstate: exited:0\n",
    )));
    try std.testing.expect(try didRepeatToolExecution(
        allocator,
        &seen,
        "EXEC_COMMAND",
        "{\"cmd\":\"ls\"}",
        "[exec-result]\nstate: exited:0\n",
    ));

    const fallback = try buildToolFallbackSummaryFromLastToolAlloc(
        allocator,
        "[tool] EXEC_COMMAND",
        "state:exited:0",
        "repeated_tool_call",
    );
    defer allocator.free(fallback);

    try std.testing.expect(std.mem.indexOf(u8, fallback, "stopped further tool calls") != null);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "[tool]") == null);
}

test "codeFenceLanguageToken extracts language from fence line" {
    try std.testing.expectEqualStrings("diff", codeFenceLanguageToken("```diff"));
    try std.testing.expectEqualStrings("zig", codeFenceLanguageToken("```  zig"));
    try std.testing.expectEqualStrings("", codeFenceLanguageToken("```"));
    try std.testing.expectEqualStrings("", codeFenceLanguageToken("plain text"));
}

test "diffRenderColorForLine tracks fenced diff and code blocks" {
    const palette = paletteForTheme(.codex);
    var state: DiffRenderState = .{};

    try std.testing.expectEqualStrings(palette.diff_meta, diffRenderColorForLine(&state, "```diff", palette));
    try std.testing.expect(state.in_fenced_block);
    try std.testing.expect(state.fenced_block_is_diff);
    try std.testing.expectEqualStrings(palette.diff_add, diffRenderColorForLine(&state, "+added", palette));
    try std.testing.expectEqualStrings(palette.dim, diffRenderColorForLine(&state, " context", palette));
    try std.testing.expectEqualStrings(palette.diff_meta, diffRenderColorForLine(&state, "```", palette));
    try std.testing.expect(!state.in_fenced_block);

    try std.testing.expectEqualStrings(palette.diff_meta, diffRenderColorForLine(&state, "```zig", palette));
    try std.testing.expect(state.in_fenced_block);
    try std.testing.expect(!state.fenced_block_is_diff);
    try std.testing.expectEqualStrings(palette.accent, diffRenderColorForLine(&state, "const x = 1;", palette));
    _ = diffRenderColorForLine(&state, "```", palette);
}

test "parseAssistantToolCall detects discovery/edit/exec/web/image/skill tools" {
    const read_tool = parseAssistantToolCall("<READ>ls</READ>").?;
    switch (read_tool) {
        .read => |command| try std.testing.expectEqualStrings("ls", command),
        else => return error.TestUnexpectedResult,
    }

    const list_dir_call = parseAssistantToolCall("<LIST_DIR>{\"path\":\"src\"}</LIST_DIR>").?;
    switch (list_dir_call) {
        .list_dir => |payload| try std.testing.expectEqualStrings("{\"path\":\"src\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const read_file_call = parseAssistantToolCall("<READ_FILE>{\"path\":\"src/main.zig\"}</READ_FILE>").?;
    switch (read_file_call) {
        .read_file => |payload| try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const grep_call = parseAssistantToolCall("<GREP_FILES>{\"query\":\"TODO\"}</GREP_FILES>").?;
    switch (grep_call) {
        .grep_files => |payload| try std.testing.expectEqualStrings("{\"query\":\"TODO\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const project_search_call = parseAssistantToolCall("<PROJECT_SEARCH>{\"query\":\"provider\"}</PROJECT_SEARCH>").?;
    switch (project_search_call) {
        .project_search => |payload| try std.testing.expectEqualStrings("{\"query\":\"provider\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const patch_call = parseAssistantToolCall(
        "*** Begin Patch\n*** Update File: src/tui.zig\n@@\n-old\n+new\n*** End Patch",
    ).?;
    switch (patch_call) {
        .apply_patch => |payload| try std.testing.expect(isValidApplyPatchPayload(payload)),
        else => return error.TestUnexpectedResult,
    }

    const exec_call = parseAssistantToolCall("<EXEC_COMMAND>{\"cmd\":\"pwd\"}</EXEC_COMMAND>").?;
    switch (exec_call) {
        .exec_command => |payload| try std.testing.expectEqualStrings("{\"cmd\":\"pwd\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const write_call = parseAssistantToolCall("<WRITE_STDIN>{\"session_id\":1,\"chars\":\"pwd\\n\"}</WRITE_STDIN>").?;
    switch (write_call) {
        .write_stdin => |payload| try std.testing.expectEqualStrings("{\"session_id\":1,\"chars\":\"pwd\\n\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const web_search_call = parseAssistantToolCall("<WEB_SEARCH>{\"query\":\"zig fmt\"}</WEB_SEARCH>").?;
    switch (web_search_call) {
        .web_search => |payload| try std.testing.expectEqualStrings("{\"query\":\"zig fmt\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const view_image_call = parseAssistantToolCall("<VIEW_IMAGE>{\"path\":\"image.png\"}</VIEW_IMAGE>").?;
    switch (view_image_call) {
        .view_image => |payload| try std.testing.expectEqualStrings("{\"path\":\"image.png\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const skill_call = parseAssistantToolCall("<SKILL>{\"name\":\"release\"}</SKILL>").?;
    switch (skill_call) {
        .skill => |payload| try std.testing.expectEqualStrings("{\"name\":\"release\"}", payload),
        else => return error.TestUnexpectedResult,
    }

    const bracket_read_call = parseAssistantToolCall("[tool] READ git log --oneline -n 5").?;
    switch (bracket_read_call) {
        .read => |command| try std.testing.expectEqualStrings("git log --oneline -n 5", command),
        else => return error.TestUnexpectedResult,
    }
}

test "parseSlashCommandPickerQuery handles slash token editing only" {
    try std.testing.expectEqualStrings("mo", parseSlashCommandPickerQuery("/mo", 3).?);
    try std.testing.expectEqualStrings("", parseSlashCommandPickerQuery("/", 1).?);
    try std.testing.expectEqualStrings("model", parseSlashCommandPickerQuery("/model test", 6).?);
    try std.testing.expect(parseSlashCommandPickerQuery("/model test", 8) == null);
    try std.testing.expect(parseSlashCommandPickerQuery("hello", 2) == null);
}

test "parseQuickActionPickerQuery handles palette query" {
    try std.testing.expectEqualStrings("", parseQuickActionPickerQuery(">", 1).?);
    try std.testing.expectEqualStrings("mod", parseQuickActionPickerQuery(">mod", 4).?);
    try std.testing.expectEqualStrings("theme", parseQuickActionPickerQuery(">  theme", 8).?);
    try std.testing.expect(parseQuickActionPickerQuery("/model", 3) == null);
}

test "parseConversationSwitchPickerQuery handles /sessions and /switch queries" {
    try std.testing.expectEqualStrings("", parseConversationSwitchPickerQuery("/sessions", 9).?);
    try std.testing.expectEqualStrings("", parseConversationSwitchPickerQuery("/sessions ", 10).?);
    try std.testing.expectEqualStrings("abc", parseConversationSwitchPickerQuery("/sessions abc", 13).?);
    try std.testing.expectEqualStrings("ab", parseConversationSwitchPickerQuery("/sessions abc", 12).?);
    try std.testing.expectEqualStrings("", parseConversationSwitchPickerQuery("/switch", 7).?);
    try std.testing.expectEqualStrings("abc", parseConversationSwitchPickerQuery("/switch abc", 11).?);
    try std.testing.expect(parseConversationSwitchPickerQuery("/session", 8) == null);
    try std.testing.expect(parseConversationSwitchPickerQuery("/swit", 5) == null);
}

test "parseProviderPickerQuery handles /provider argument edits" {
    try std.testing.expectEqualStrings("", parseProviderPickerQuery("/provider", 9).?);
    try std.testing.expectEqualStrings("", parseProviderPickerQuery("/provider ", 10).?);
    try std.testing.expectEqualStrings("op", parseProviderPickerQuery("/provider op", 12).?);
    try std.testing.expectEqualStrings("openai codex", parseProviderPickerQuery("/provider openai codex", 22).?);
    try std.testing.expect(parseProviderPickerQuery("/provider", 4) == null);
    try std.testing.expect(parseProviderPickerQuery("/providerx", 10) == null);
}

test "collectConversationSwitchMatchOrder sorts newest conversations first" {
    const allocator = std.testing.allocator;
    var conversations = [_]Conversation{
        .{
            .id = @constCast("a1"),
            .title = @constCast("alpha"),
            .created_ms = 100,
            .updated_ms = 100,
        },
        .{
            .id = @constCast("b2"),
            .title = @constCast("beta"),
            .created_ms = 200,
            .updated_ms = 900,
        },
        .{
            .id = @constCast("c3"),
            .title = @constCast("charlie"),
            .created_ms = 300,
            .updated_ms = 500,
        },
    };

    var ordered = try collectConversationSwitchMatchOrder(allocator, conversations[0..], 0, "", true);
    defer ordered.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), ordered.items.len);
    try std.testing.expectEqual(@as(usize, 1), ordered.items[0]);
    try std.testing.expectEqual(@as(usize, 2), ordered.items[1]);
    try std.testing.expectEqual(@as(usize, 0), ordered.items[2]);
}

test "collectConversationSwitchMatchOrder uses created time then index as tie-breakers" {
    const allocator = std.testing.allocator;
    var conversations = [_]Conversation{
        .{
            .id = @constCast("a1"),
            .title = @constCast("new title"),
            .created_ms = 100,
            .updated_ms = 1_000,
        },
        .{
            .id = @constCast("b2"),
            .title = @constCast("newer"),
            .created_ms = 200,
            .updated_ms = 1_000,
        },
        .{
            .id = @constCast("c3"),
            .title = @constCast("newest"),
            .created_ms = 200,
            .updated_ms = 1_000,
        },
    };

    var ordered = try collectConversationSwitchMatchOrder(allocator, conversations[0..], 0, "new", true);
    defer ordered.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), ordered.items.len);
    try std.testing.expectEqual(@as(usize, 2), ordered.items[0]);
    try std.testing.expectEqual(@as(usize, 1), ordered.items[1]);
    try std.testing.expectEqual(@as(usize, 0), ordered.items[2]);
}

test "collectConversationSwitchMatchOrder hides all blank drafts when disabled" {
    const allocator = std.testing.allocator;
    var conversations = [_]Conversation{
        .{
            .id = @constCast("a1"),
            .title = @constCast("draft-current"),
            .created_ms = 100,
            .updated_ms = 100,
        },
        .{
            .id = @constCast("b2"),
            .title = @constCast("active"),
            .created_ms = 200,
            .updated_ms = 900,
        },
        .{
            .id = @constCast("c3"),
            .title = @constCast("draft-hidden"),
            .created_ms = 300,
            .updated_ms = 500,
        },
    };
    defer {
        for (conversations[0].messages.items) |*message| message.deinit(allocator);
        conversations[0].messages.deinit(allocator);
        for (conversations[1].messages.items) |*message| message.deinit(allocator);
        conversations[1].messages.deinit(allocator);
        for (conversations[2].messages.items) |*message| message.deinit(allocator);
        conversations[2].messages.deinit(allocator);
    }

    try conversations[1].messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "hello"),
        .timestamp_ms = 901,
    });

    var ordered = try collectConversationSwitchMatchOrder(allocator, conversations[0..], 0, "", false);
    defer ordered.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), ordered.items.len);
    try std.testing.expectEqual(@as(usize, 1), ordered.items[0]);
}

test "conversationRelativeAge formats relative units" {
    const now_ms: i64 = 1_000_000;

    const just_now = conversationRelativeAge(now_ms, now_ms - 2_000);
    try std.testing.expect(just_now.just_now);

    const seconds = conversationRelativeAge(now_ms, now_ms - 42_000);
    try std.testing.expect(!seconds.just_now);
    try std.testing.expectEqual(@as(i64, 42), seconds.value);
    try std.testing.expectEqualStrings("s", seconds.unit);

    const minutes = conversationRelativeAge(now_ms, now_ms - (12 * 60_000));
    try std.testing.expectEqual(@as(i64, 12), minutes.value);
    try std.testing.expectEqualStrings("m", minutes.unit);

    const hours = conversationRelativeAge(now_ms, now_ms - (5 * 3_600_000));
    try std.testing.expectEqual(@as(i64, 5), hours.value);
    try std.testing.expectEqualStrings("h", hours.unit);

    const days = conversationRelativeAge(now_ms, now_ms - (3 * 86_400_000));
    try std.testing.expectEqual(@as(i64, 3), days.value);
    try std.testing.expectEqualStrings("d", days.unit);
}

test "conversationAgeLabelAlloc renders now and ago labels" {
    const allocator = std.testing.allocator;

    const now_label = try conversationAgeLabelAlloc(allocator, .{ .just_now = true });
    defer allocator.free(now_label);
    try std.testing.expectEqualStrings("now", now_label);

    const ago_label = try conversationAgeLabelAlloc(allocator, .{ .value = 12, .unit = "m" });
    defer allocator.free(ago_label);
    try std.testing.expectEqualStrings("12m ago", ago_label);
}

test "sessionPickerTitleMaxWidth caps to available width" {
    try std.testing.expectEqual(@as(usize, 0), sessionPickerTitleMaxWidth(20, 16, 6));
    try std.testing.expectEqual(@as(usize, 35), sessionPickerTitleMaxWidth(64, 16, 6));
    try std.testing.expectEqual(@as(usize, 56), sessionPickerTitleMaxWidth(200, 16, 6));
}

test "commandMatchesQuery matches name and description" {
    const entry: BuiltinCommandEntry = .{
        .name = "provider",
        .description = "set/show provider id",
    };
    try std.testing.expect(commandMatchesQuery(entry, "prov"));
    try std.testing.expect(commandMatchesQuery(entry, "show"));
    try std.testing.expect(!commandMatchesQuery(entry, "xyz"));
}

test "deriveConversationTitleFromPrompt trims and normalizes spaces" {
    const allocator = std.testing.allocator;
    const title = try App.deriveConversationTitleFromPrompt(allocator, "   this   is   a   test prompt title   ");
    defer allocator.free(title);
    try std.testing.expectEqualStrings("this is a test prompt title", title);
}

test "deriveConversationTitleFromPrompt preserves long prompt preview" {
    const allocator = std.testing.allocator;
    const prompt =
        "this is a deliberately long first prompt that should remain intact as the conversation preview title";
    const title = try App.deriveConversationTitleFromPrompt(allocator, prompt);
    defer allocator.free(title);
    try std.testing.expectEqualStrings(prompt, title);
}

test "shouldRenderDiffMode ignores regular code fences and detects diff fences" {
    const message = struct {
        role: Role = .assistant,
        content: []const u8 = "",
    }{};

    try std.testing.expect(!shouldRenderDiffMode(message, "```zig\nconst x = 1;\n```"));
    try std.testing.expect(shouldRenderDiffMode(message, "```diff\n+ add\n```"));
}

test "prepareMarkdownLineAlloc handles heading and fenced code state" {
    const allocator = std.testing.allocator;
    var state: MarkdownRenderState = .{};

    var heading = try prepareMarkdownLineAlloc(allocator, "## Heading", &state);
    defer heading.deinit(allocator);
    try std.testing.expectEqual(MarkdownLineKind.heading, heading.kind);
    try std.testing.expectEqualStrings("Heading", heading.text);

    var fence_open = try prepareMarkdownLineAlloc(allocator, "```zig", &state);
    defer fence_open.deinit(allocator);
    try std.testing.expectEqual(MarkdownLineKind.fence, fence_open.kind);
    try std.testing.expectEqualStrings("[code: zig]", fence_open.text);

    var code_line = try prepareMarkdownLineAlloc(allocator, "const x = 1;", &state);
    defer code_line.deinit(allocator);
    try std.testing.expectEqual(MarkdownLineKind.code, code_line.kind);
    try std.testing.expect(!code_line.wrap_on_words);
}

test "registerStreamInterruptByte requires double esc within window" {
    var esc_count: u8 = 0;
    var last_esc_ms: i64 = 0;

    try std.testing.expect(!registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 1000));
    try std.testing.expectEqual(@as(u8, 1), esc_count);

    try std.testing.expect(registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 1500));
    try std.testing.expectEqual(@as(u8, 0), esc_count);
}

test "registerStreamInterruptByte resets on non-esc and timeout" {
    var esc_count: u8 = 0;
    var last_esc_ms: i64 = 0;

    _ = registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 1000);
    try std.testing.expect(!registerStreamInterruptByte(&esc_count, &last_esc_ms, 'a', 1001));
    try std.testing.expectEqual(@as(u8, 0), esc_count);

    _ = registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 2000);
    try std.testing.expect(!registerStreamInterruptByte(&esc_count, &last_esc_ms, 27, 4005));
    try std.testing.expectEqual(@as(u8, 1), esc_count);
}

test "isAllowedReadCommand allowlist and slash rejection" {
    try std.testing.expect(isAllowedReadCommand(&.{"rg"}));
    try std.testing.expect(isAllowedReadCommand(&.{"ls"}));
    try std.testing.expect(!isAllowedReadCommand(&.{"bash"}));
    try std.testing.expect(!isAllowedReadCommand(&.{"/usr/bin/rg"}));
}

test "collectAtFileReferences parses unique @path tokens" {
    const allocator = std.testing.allocator;
    const text = "review @src/main.zig and @src/tui.zig then @src/main.zig again";

    var refs = try collectAtFileReferences(allocator, text);
    defer {
        for (refs.items) |entry| allocator.free(entry);
        refs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("src/main.zig", refs.items[0]);
    try std.testing.expectEqualStrings("src/tui.zig", refs.items[1]);
}

test "collectDollarSkillReferences parses unique $skill mentions" {
    const allocator = std.testing.allocator;
    const text = "use $release-note then ($lint_fix), [$test-suite], and $release-note again";

    var refs = try collectDollarSkillReferences(allocator, text);
    defer {
        for (refs.items) |entry| allocator.free(entry);
        refs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 3), refs.items.len);
    try std.testing.expectEqualStrings("release-note", refs.items[0]);
    try std.testing.expectEqualStrings("lint_fix", refs.items[1]);
    try std.testing.expectEqualStrings("test-suite", refs.items[2]);
}

test "collectAtFileReferences parses quoted @path with spaces" {
    const allocator = std.testing.allocator;
    const text = "review @\"docs/My File.md\" then @'src/other file.zig'";

    var refs = try collectAtFileReferences(allocator, text);
    defer {
        for (refs.items) |entry| allocator.free(entry);
        refs.deinit(allocator);
    }

    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqualStrings("docs/My File.md", refs.items[0]);
    try std.testing.expectEqualStrings("src/other file.zig", refs.items[1]);
}

test "currentAtTokenRange detects @token under cursor" {
    const text = "review @src/main.zig now";
    const token = currentAtTokenRange(text, 11) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("src/main.zig", token.query);
    try std.testing.expectEqual(@as(usize, 7), token.start);
    try std.testing.expectEqual(@as(usize, 20), token.end);
}

test "rewriteInputWithSelectedAtPath inserts selected file token" {
    const allocator = std.testing.allocator;
    const rewritten = try rewriteInputWithSelectedAtPath(allocator, "review @sr now", 9, "src/main.zig");
    defer allocator.free(rewritten.text);

    try std.testing.expectEqualStrings("review @src/main.zig now", rewritten.text);
    try std.testing.expectEqual(@as(usize, 21), rewritten.cursor);
}

test "rewriteInputWithSelectedAtPath quotes path with spaces" {
    const allocator = std.testing.allocator;
    const rewritten = try rewriteInputWithSelectedAtPath(allocator, "check @do", 8, "docs/My File.md");
    defer allocator.free(rewritten.text);

    try std.testing.expectEqualStrings("check @\"docs/My File.md\" ", rewritten.text);
}

test "insertAtPathTokenAtCursor inserts token when no @ context exists" {
    const allocator = std.testing.allocator;
    const rewritten = try insertAtPathTokenAtCursor(allocator, "hello world", 5, "tmp/img.png");
    defer allocator.free(rewritten.text);

    try std.testing.expectEqualStrings("hello @tmp/img.png world", rewritten.text);
    try std.testing.expectEqual(@as(usize, 18), rewritten.cursor);
}

test "computeInputCursorPlacement anchors cursor to input marker" {
    const placement = computeInputCursorPlacement(
        120,
        40,
        true,
        30,
        0,
        3,
    );

    try std.testing.expectEqual(@as(usize, 36), placement.row);
    try std.testing.expectEqual(@as(usize, 11), placement.col);
}

test "buildInputView hides inline marker and preserves cursor column" {
    const allocator = std.testing.allocator;
    const view = try buildInputView(allocator, "hello", " world", 64);
    defer allocator.free(view.text);

    try std.testing.expectEqualStrings("hello world", view.text);
    try std.testing.expectEqual(@as(usize, 5), view.cursor_col);
}

test "buildFileInjectionPayload includes readable files and reports counts" {
    const allocator = std.testing.allocator;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const abs_dir = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs_dir);

    const file_path = try std.fs.path.join(allocator, &.{ abs_dir, "inject.txt" });
    defer allocator.free(file_path);

    var file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
    defer file.close();
    var write_buf: [256]u8 = undefined;
    var file_writer = file.writer(&write_buf);
    defer file_writer.interface.flush() catch {};
    try file_writer.interface.writeAll("hello inject\n");
    try file_writer.interface.flush();

    const prompt = try std.fmt.allocPrint(allocator, "check @{s} and @missing.txt", .{file_path});
    defer allocator.free(prompt);

    const result = try buildFileInjectionPayload(allocator, prompt);
    defer if (result.payload) |payload| allocator.free(payload);

    try std.testing.expectEqual(@as(usize, 2), result.referenced_count);
    try std.testing.expectEqual(@as(usize, 1), result.included_count);
    try std.testing.expectEqual(@as(usize, 1), result.skipped_count);
    try std.testing.expect(result.payload != null);
    try std.testing.expect(std.mem.indexOf(u8, result.payload.?, "<file path=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.payload.?, "hello inject") != null);
}

test "buildFileInjectionPayload includes image metadata for @image path" {
    const allocator = std.testing.allocator;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const abs_dir = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs_dir);

    const image_path = try std.fs.path.join(allocator, &.{ abs_dir, "sample.png" });
    defer allocator.free(image_path);

    var image_file = try std.fs.createFileAbsolute(image_path, .{ .truncate = true });
    defer image_file.close();
    const png_header = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x02, // width=2
        0x00, 0x00, 0x00, 0x03, // height=3
    };
    try image_file.writeAll(png_header[0..]);

    const prompt = try std.fmt.allocPrint(allocator, "look @{s}", .{image_path});
    defer allocator.free(prompt);

    const result = try buildFileInjectionPayload(allocator, prompt);
    defer if (result.payload) |payload| allocator.free(payload);

    try std.testing.expectEqual(@as(usize, 1), result.referenced_count);
    try std.testing.expectEqual(@as(usize, 1), result.included_count);
    try std.testing.expectEqual(@as(usize, 0), result.skipped_count);
    try std.testing.expect(result.payload != null);
    try std.testing.expect(std.mem.indexOf(u8, result.payload.?, "<image path=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.payload.?, "mime=\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.payload.?, "width=\"2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.payload.?, "height=\"3\"") != null);
}

test "inspectImageFile parses png metadata and sha256" {
    const allocator = std.testing.allocator;
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const abs_dir = try temp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(abs_dir);

    const image_path = try std.fs.path.join(allocator, &.{ abs_dir, "inspect.png" });
    defer allocator.free(image_path);

    var image_file = try std.fs.createFileAbsolute(image_path, .{ .truncate = true });
    defer image_file.close();
    const png_header = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x08, // width=8
        0x00, 0x00, 0x00, 0x09, // height=9
        0x08, 0x02, 0x00, 0x00,
        0x00,
    };
    try image_file.writeAll(png_header[0..]);

    var info = (try inspectImageFile(allocator, image_path, true)).?;
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings("png", info.format);
    try std.testing.expectEqualStrings("image/png", info.mime);
    try std.testing.expectEqual(@as(u32, 8), info.width.?);
    try std.testing.expectEqual(@as(u32, 9), info.height.?);
    try std.testing.expect(info.sha256_hex != null);
    try std.testing.expectEqual(@as(usize, 64), info.sha256_hex.?.len);
}

test "formatTokenCount trims trailing .0 for compact context display" {
    const allocator = std.testing.allocator;

    const a = try formatTokenCount(allocator, 105_000);
    defer allocator.free(a);
    try std.testing.expectEqualStrings("105k", a);

    const b = try formatTokenCount(allocator, 225_000);
    defer allocator.free(b);
    try std.testing.expectEqualStrings("225k", b);

    const c = try formatTokenCount(allocator, 123_456);
    defer allocator.free(c);
    try std.testing.expectEqualStrings("123.5k", c);
}

test "buildWorkingPlaceholder includes task timer and interrupt hint" {
    const allocator = std.testing.allocator;

    const placeholder = try buildWorkingPlaceholder(allocator, "Thinking", 1_000, 6_500);
    defer allocator.free(placeholder);

    try std.testing.expect(std.mem.indexOf(u8, placeholder, "Working (5s") != null);
    try std.testing.expect(std.mem.indexOf(u8, placeholder, "esc to interrupt") != null);
}

test "buildStreamingNotice includes task and elapsed timer" {
    const allocator = std.testing.allocator;

    const notice = try buildStreamingNotice(allocator, "Running READ", 2_000, 7_100);
    defer allocator.free(notice);

    try std.testing.expect(std.mem.indexOf(u8, notice, "Running READ (5s") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "esc to interrupt") != null);
}

test "parseOpenAiAuthModeName supports known values" {
    try std.testing.expect(parseOpenAiAuthModeName("auto").? == .auto);
    try std.testing.expect(parseOpenAiAuthModeName("api_key").? == .api_key);
    try std.testing.expect(parseOpenAiAuthModeName("codex").? == .codex);
    try std.testing.expect(parseOpenAiAuthModeName("unknown") == null);
}

test "extractAvailableSkillsSummaryAlloc parses available skills section" {
    const allocator = std.testing.allocator;
    const agents_text =
        \\## Skills
        \\### Available skills
        \\- alpha-tool: Alpha description
        \\- beta-tool: Beta description
        \\### How to use skills
        \\- ignored: this section is not part of available skills
    ;

    const summary = try extractAvailableSkillsSummaryAlloc(allocator, agents_text);
    defer if (summary) |text| allocator.free(text);

    try std.testing.expect(summary != null);
    try std.testing.expectEqualStrings("- alpha-tool: Alpha description\n- beta-tool: Beta description", summary.?);
}

test "messageDisplayContent collapses agents context payload" {
    const sample = struct {
        role: Role,
        content: []const u8,
    }{
        .role = .system,
        .content = "[agents-context]\nsource: /tmp/AGENTS.md\nworkspace_instructions:\nhello",
    };

    const visible = messageDisplayContent(sample);
    try std.testing.expectEqualStrings("[agents-context]", visible);
}

test "messageDisplayContent collapses compact summary payload" {
    const sample = struct {
        role: Role,
        content: []const u8,
    }{
        .role = .system,
        .content = "[compact-summary]\n- goal: keep working\n- next: finish tests",
    };

    const visible = messageDisplayContent(sample);
    try std.testing.expectEqualStrings("[compact-summary]", visible);
}

test "isCompactionSourceMessage keeps user-assistant text and skips tool calls" {
    const user_message = struct {
        role: Role,
        content: []const u8,
    }{
        .role = .user,
        .content = "please continue",
    };
    try std.testing.expect(isCompactionSourceMessage(user_message));

    const tool_call_message = struct {
        role: Role,
        content: []const u8,
    }{
        .role = .assistant,
        .content = "<READ>ls</READ>",
    };
    try std.testing.expect(!isCompactionSourceMessage(tool_call_message));

    const system_message = struct {
        role: Role,
        content: []const u8,
    }{
        .role = .system,
        .content = "metadata",
    };
    try std.testing.expect(!isCompactionSourceMessage(system_message));
}

test "extractChatgptAccountIdFromJwtAlloc parses nested auth claim" {
    const allocator = std.testing.allocator;

    const payload_json =
        \\{"https://api.openai.com/auth":{"chatgpt_account_id":"acc_nested_123"}}
    ;
    const payload_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len);
    const payload_b64 = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload_b64);
    _ = std.base64.url_safe_no_pad.Encoder.encode(payload_b64, payload_json);

    const header = "e30"; // {}
    const signature = "c2ln"; // sig
    const jwt = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header, payload_b64, signature });
    defer allocator.free(jwt);

    const account_id = try extractChatgptAccountIdFromJwtAlloc(allocator, jwt);
    defer if (account_id) |value| allocator.free(value);

    try std.testing.expect(account_id != null);
    try std.testing.expectEqualStrings("acc_nested_123", account_id.?);
}

test "extractChatgptAccountIdFromClaims supports organizations fallback" {
    const allocator = std.testing.allocator;
    const payload_json =
        \\{"organizations":[{"id":"org_abc"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
    defer parsed.deinit();

    const claims = switch (parsed.value) {
        .object => |object| object,
        else => return error.TestUnexpectedResult,
    };

    const account_id = extractChatgptAccountIdFromClaims(claims);
    try std.testing.expect(account_id != null);
    try std.testing.expectEqualStrings("org_abc", account_id.?);
}
