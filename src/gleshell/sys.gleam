//// OS / process FFI wrappers.

@external(erlang, "gleshell_ffi", "get_line")
pub fn get_line(prompt: String) -> Result(String, String)

/// Run `body` as the OTP interactive shell process so the REPL gets
/// edlin line editing: history (up/down) and Ctrl+R reverse-i-search.
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

@external(erlang, "gleshell_ffi", "run_cmd")
pub fn run_cmd(
  command: String,
  args: List(String),
) -> Result(#(Int, String), String)

@external(erlang, "gleshell_ffi", "which")
pub fn which(command: String) -> Result(String, Nil)

@external(erlang, "gleshell_ffi", "home_dir")
pub fn home_dir() -> Result(String, String)

@external(erlang, "gleshell_ffi", "stdout_isatty")
pub fn stdout_isatty() -> Bool
