//// OS / process FFI wrappers.

@external(erlang, "gleshell_ffi", "get_line")
pub fn get_line(prompt: String) -> Result(String, String)

/// Print a line to stdout. In raw TTY REPL mode, newlines become CRLF so
/// multi-line values (tables, pretty JSON) do not staircase.
@external(erlang, "gleshell_ffi", "println")
pub fn println(text: String) -> Nil

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

@external(erlang, "gleshell_ffi", "home_dir")
pub fn home_dir() -> Result(String, String)

@external(erlang, "gleshell_ffi", "stdout_isatty")
pub fn stdout_isatty() -> Bool
