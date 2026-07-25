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
@external(erlang, "gleshell_ffi", "run_cmd")
pub fn run_cmd(
  command: String,
  args: List(String),
) -> Result(#(Int, String), String)

/// Run an external command in the foreground on the real TTY when possible
/// (`less`, `vim`, …). Falls back to capture when stdout is not a terminal.
@external(erlang, "gleshell_ffi", "run_cmd_tty")
pub fn run_cmd_tty(
  command: String,
  args: List(String),
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

@external(erlang, "gleshell_ffi", "home_dir")
pub fn home_dir() -> Result(String, String)

@external(erlang, "gleshell_ffi", "stdout_isatty")
pub fn stdout_isatty() -> Bool
