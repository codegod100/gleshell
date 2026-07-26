//// OS / process FFI wrappers.

@external(erlang, "gleshell_ffi", "get_line")
pub fn get_line(prompt: String) -> Result(String, String)

/// Print a line to stdout. In raw TTY REPL mode, newlines become CRLF so
/// multi-line values (tables, pretty JSON) do not staircase.
@external(erlang, "gleshell_ffi", "println")
pub fn println(text: String) -> Nil

/// Write text with no automatic trailing newline. ANSI is passed through.
/// In raw TTY REPL mode, bare LFs become CRLF (same staircase fix as `println`).
@external(erlang, "gleshell_ffi", "write")
pub fn write(text: String) -> Nil

/// Terminal `{rows, cols}` when stdout is a TTY; Error otherwise.
@external(erlang, "gleshell_ffi", "term_size")
pub fn term_size() -> Result(#(Int, Int), Nil)

/// One keypress for the builtin pager. See `gleshell_ffi:read_key_name/0`.
/// Prefer calling inside `with_key_mode` when not in the raw REPL.
@external(erlang, "gleshell_ffi", "read_key_name")
pub fn read_key_name() -> Result(String, String)

/// Run `body` with the TTY in single-key mode when needed (non-raw REPL).
@external(erlang, "gleshell_ffi", "with_key_mode")
pub fn with_key_mode(body: fn() -> Nil) -> Nil

/// Run `body` as the interactive shell (raw TTY editor when possible).
/// Ensures Erlang `+Bc` so Ctrl+C cancels the line instead of aborting the VM.
@external(erlang, "gleshell_ffi", "run_as_shell")
pub fn run_as_shell(body: fn() -> Nil) -> Nil

@external(erlang, "gleshell_ffi", "set_cwd")
pub fn set_cwd(path: String) -> Result(Nil, String)

@external(erlang, "gleshell_ffi", "get_cwd")
pub fn get_cwd() -> Result(String, String)

@external(erlang, "gleshell_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "gleshell_ffi", "setenv")
pub fn setenv(name: String, value: String) -> Result(Nil, Nil)

/// All process environment variables as `(name, value)` pairs.
@external(erlang, "gleshell_ffi", "list_env")
pub fn list_env() -> List(#(String, String))

/// Run an external command capturing stdout/stderr (pipelines, `let`, non-TTY).
/// `stdin` is fed to the process (empty → `/dev/null`).
@external(erlang, "gleshell_ffi", "run_cmd")
pub fn run_cmd(
  command: String,
  args: List(String),
  stdin: String,
) -> Result(#(Int, String), String)

/// Run an external command in the foreground on a TTY when possible
/// (`less`, `vim`, `bat`, `fastfetch`, …). Prefers a PTY (`script`) so keys —
/// including Ctrl+C → SIGINT — reach the child. Pipeline `stdin` is still fed
/// when non-empty (e.g. `cat file | less`). Falls back to capture when stdout
/// is not a terminal, or to plain inherit if `script` is unavailable.
///
/// In the raw-mode REPL the controlling TTY is briefly switched to cooked
/// termios (with ISIG off) for the child and restored after, so LF-only output
/// does not staircase and Ctrl+C does not open the Erlang BREAK menu.
@external(erlang, "gleshell_ffi", "run_cmd_tty")
pub fn run_cmd_tty(
  command: String,
  args: List(String),
  stdin: String,
) -> Result(#(Int, String), String)

/// True if the last external command already streamed its output to the TTY
/// (inherit or PTY relay). Consumes the flag.
@external(erlang, "gleshell_ffi", "take_output_shown")
pub fn take_output_shown() -> Bool

/// Clear the "output already shown" flag (e.g. after a builtin transforms data).
@external(erlang, "gleshell_ffi", "clear_output_shown")
pub fn clear_output_shown() -> Nil

@external(erlang, "gleshell_ffi", "which")
pub fn which(command: String) -> Result(String, Nil)

/// All matching executables on `PATH` (or the path itself if it contains `/`).
@external(erlang, "gleshell_ffi", "which_all")
pub fn which_all(command: String) -> List(String)

/// Canonical absolute path: resolve `.`/`..` and follow all symlinks.
/// Error if the path does not exist or the link chain loops / is broken.
@external(erlang, "gleshell_ffi", "realpath")
pub fn realpath(path: String) -> Result(String, Nil)

/// True if `text` matches Erlang regex `pattern`. `ignore_case` enables caseless.
/// Error string on invalid pattern.
@external(erlang, "gleshell_ffi", "re_contains")
pub fn re_contains(
  text: String,
  pattern: String,
  ignore_case: Bool,
) -> Result(Bool, String)

/// Tab-completion candidates for `word` given the text before it on the line.
/// Returns `(matches, kind)` where kind is `"command"` or `"path"`.
@external(erlang, "gleshell_ffi", "complete_word")
pub fn complete_word(prefix: String, word: String) -> #(List(String), String)

/// Greyed-out history autosuggestion suffix for `buffer`, given `history`
/// newest-first. Empty string when there is no proper prefix match.
@external(erlang, "gleshell_ffi", "history_hint")
pub fn history_hint(history: List(String), buffer: String) -> String

/// Fuzzy history filter for Ctrl+R reverse search (stinkpot-style).
/// `history` is newest-first; empty/whitespace `query` returns all unique
/// entries in that order. Non-empty query returns subsequence fuzzy matches,
/// best scores first (ties keep newest-first order).
@external(erlang, "gleshell_ffi", "history_search")
pub fn history_search(history: List(String), query: String) -> List(String)

@external(erlang, "gleshell_ffi", "home_dir")
pub fn home_dir() -> Result(String, String)

@external(erlang, "gleshell_ffi", "stdout_isatty")
pub fn stdout_isatty() -> Bool

/// Format Unix epoch seconds as local `Jul 3 2026 9:39:40 PM` (12-hour).
@external(erlang, "gleshell_ffi", "format_unix_local")
pub fn format_unix_local(seconds: Int) -> String

/// One process row from `list_processes` (Nushell `ps` columns).
/// Memory fields are bytes; `start_time` is Unix epoch seconds (0 if unknown).
pub type ProcessInfo {
  ProcessInfo(
    pid: Int,
    ppid: Int,
    name: String,
    status: String,
    cpu: Float,
    mem: Int,
    virtual: Int,
    command: String,
    start_time: Int,
    user_id: Int,
    process_group_id: Int,
    session_id: Int,
    priority: Int,
    process_threads: Int,
    working: Int,
    paged: Int,
    cwd: String,
  )
}

/// System processes (Linux `/proc`; empty list on unsupported OS).
/// Samples CPU over ~100ms like Nushell `ps`.
@external(erlang, "gleshell_ffi", "list_processes")
pub fn list_processes() -> List(ProcessInfo)
